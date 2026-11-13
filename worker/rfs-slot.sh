#!/bin/bash
# rfs-slot: share the dev box's memory and GPU between RigForSilent runs, first come first served.
#   rfs-slot [--first] COMMAND [ARGS...]   queue for a slot, run COMMAND in it, free the slot
#   rfs-slot --status                      the slots, who holds them, and the queue
#   rfs-slot --help                        this text (queues nothing)
# There are TMD_SLOTS memory tokens of TMD_SLOT_GB (default 9). By default they fill the container's
# memory cap after TMD_RESERVE_GB (default 10) for Claude sessions, agents and shells, at most 4:
# three at 48 GB beside the render slot. An import of a lane far behind its cache peaks at 9-10.6 GB,
# and four 7 GB slots got the container OOM-killed at 40 GB (26 Oct). A whole-suite test run (all,
# quick, slow, landing or a folder) takes every memory token free when its turn comes and runs that
# many shards; landing keeps one for the lint and net-e2e. Anything else takes one token.
# Renders have their own TMD_SLOT_RENDERS tokens (default 1) of TMD_SLOT_RENDER_GB (default 4), set
# aside from the cap first. Three kinds of run:
#   render  tools/shot.sh, or tools/godot.sh opening a scene without --headless, --import or --test:
#           a render token, or any free memory token.
#   gpu     tools/bake.sh and tools/bpy.sh (Cycles): a render token only, so one GPU job runs at a
#           time and the card never sits idle behind imports (11 Nov). A bake first imports in a
#           memory slot (tools/godot.sh --import), so its import never holds the GPU.
#   memory  everything else (imports, tests, headless runs): a memory token.
# TMD_SLOT_KIND=memory|render|gpu overrides the guess; TMD_RENDER=1|0 still means render|memory.
# The queue: each waiting run holds a ticket, oldest first. A run may take a token only when no older
# live ticket wants that kind of token, so long waiters never starve (until 11 Nov it polled
# `flock -n` and whoever looked first won). --first (the seed refresh) queues ahead of every normal
# ticket. A ticket whose run died is dropped by the next waiter that looks.
# A run gives up after TMD_SLOT_MAX_WAIT minutes in the queue (default 60; 0 waits forever) with
# exit code 75 and "still queued": it ran nothing, so run it again. An agent's Bash background run
# is stopped at 2 h, wait included, so it should not wait past that and get stopped mid-import.
# Its ticket keeps its place for TMD_SLOT_LEASE minutes (default 15) after it gives up: the same
# command run again from the same folder (or with the same TMD_SLOT_TICKET) takes the old ticket
# back, so it doesn't go to the end of the line (13 Nov). A ticket on lease never holds others back.
# A run with nothing to do (tools/tmd.py precheck: an import with nothing newer than its stamp, a
# suite that passed unchanged) neither queues nor runs; TMD_SLOT_PRECHECK=0 turns that off (13 Nov).
# Don't wrap a chain of runs (import && test && shot) in one rfs-slot: it holds the slot throughout.
# Each run logs a "start" line (its wait) and an "end" line (run time, exit code) in TMD_SLOT_LOG
# (default ~/.rfs-slots/slot.log, tab-separated). Tokens are lock files held while the command
# runs, so they free themselves when it ends or is killed. Each setting also reads its old RFS_*
# name when the TMD_* one is unset. The render count isn't TMD_RENDER_SLOTS: tools/tmd.py uses
# that for its own windows.
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

# The cgroup's cap in GB (v2, then v1), or empty when there is none.
cap_gb() {
  local raw
  raw="$(cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || true)"
  [[ "$raw" =~ ^[0-9]+$ ]] && [ "$raw" -lt $((1 << 50)) ] && echo $((raw / 1024 / 1024 / 1024))
}
render_slots="${TMD_SLOT_RENDERS:-${RFS_RENDER_SLOTS:-1}}"
slots="${TMD_SLOTS:-${RFS_SLOTS:-}}"
if [ -z "$slots" ]; then
  cap="$(cap_gb || true)" slots=4
  if [ -n "$cap" ]; then
    slots=$(((cap - ${TMD_RESERVE_GB:-${RFS_RESERVE_GB:-10}} - render_slots * ${TMD_SLOT_RENDER_GB:-${RFS_RENDER_GB:-4}}) / ${TMD_SLOT_GB:-${RFS_SLOT_GB:-9}}))
    [ "$slots" -le 4 ] || slots=4
    [ "$slots" -ge 1 ] || slots=1
  fi
fi
dir="${TMD_SLOT_DIR:-${RFS_SLOT_DIR:-$HOME/.rfs-slots}}"
queue="$dir/queue"
log="${TMD_SLOT_LOG:-$dir/slot.log}"
# Minutes, or seconds with an s (30s), as seconds.
seconds() { if [[ "$1" == *s ]]; then echo "${1%s}"; else echo $(($1 * 60)); fi; }
max_wait="$(seconds "${TMD_SLOT_MAX_WAIT:-60}")"
lease="$(seconds "${TMD_SLOT_LEASE:-15}")"
mkdir -p "$queue"

all_tokens() {
  local i
  for ((i = 0; i < render_slots; i++)); do echo "render.$i"; done
  for ((i = 0; i < slots; i++)); do echo "token.$i"; done
}

# The tickets oldest first, as "NAME waiting" (a live run holds its lock) or "NAME lease" (its run
# gave up less than TMD_SLOT_LEASE ago and may come back); drops the rest (runs that died, leases
# that ran out). Names are a priority digit, a fixed-width time and a key, so they sort as text.
tickets() {
  local name lease_end
  while read -r name; do
    [ -n "$name" ] || continue
    if ! flock -n "$queue/$name" true 2>/dev/null; then echo "$name waiting"; continue; fi
    lease_end="$(cat "$queue/.lease.$name" 2>/dev/null || echo 0)"
    if [ "$lease_end" -gt "$(date +%s)" ] 2>/dev/null; then echo "$name lease"; continue; fi
    rm -f "$queue/$name" "$queue/.lease.$name"
  done < <(cd "$queue" && ls -1 | grep '^[0-9]' | LC_ALL=C sort)
}
live_tickets() { tickets | awk '$2 == "waiting" { print $1 }'; }

# One ticket for people: kind, minutes queued, worktree, command.
describe_ticket() {
  local kind want pid since cwd cmd
  IFS=$'\t' read -r kind want pid since cwd cmd < "$queue/$1" 2>/dev/null || return 0
  echo "$kind, $((($(date +%s) - since) / 60)) min, $(basename "$cwd"): $cmd"
}

status() {
  local t who
  echo "slots ($slots memory of ${TMD_SLOT_GB:-${RFS_SLOT_GB:-9}} GB, $render_slots render):"
  for t in $(all_tokens); do
    if [ ! -e "$dir/$t" ] || flock -n "$dir/$t" true 2>/dev/null; then
      echo "  $t  free"
    else
      who="$(cat "$dir/$t.who" 2>/dev/null || echo "?")"
      echo "  $t  busy: $who"
    fi
  done
  local lines=() line
  mapfile -t lines < <(tickets)
  echo "queue (${#lines[@]}, oldest first; \"left\": gave up, keeps its place for a while):"
  for line in "${lines[@]}"; do
    echo "  $(describe_ticket "${line% *}")$([ "${line#* }" = lease ] && echo "  (left)")"
  done
}

first=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --status) status; exit 0 ;;
    --first) first=1; shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done
[ $# -gt 0 ] || { usage >&2; exit 2; }
# A command's own help needs no slot.
case "${2:-}" in -h | --help) exec "$@" ;; esac

# Whether the command draws on the GPU rather than the CPU (see the top).
is_render() {
  case "$(basename "$1")" in
    shot.sh | shot.cmd) return 0 ;;
    godot.sh | godot.cmd) ;;
    *) return 1 ;;
  esac
  local arg scene=1
  for arg in "${@:2}"; do
    case "$arg" in
      --) break ;;
      --headless | --import | --test* | -e | --editor) return 1 ;;
      res://*.tscn | *.tscn) scene=0 ;;
    esac
  done
  return "$scene"
}

slot_kind() {
  local force="${TMD_SLOT_KIND:-}" old="${TMD_RENDER:-${RFS_RENDER:-}}"
  if [ -n "$force" ]; then echo "$force"; return; fi
  if [ -n "$old" ]; then { [ "$old" = 1 ] && echo render; } || echo memory; return; fi
  case "$(basename "$1")" in
    bake.sh | bake.cmd | bpy.sh | bpy.cmd) echo gpu; return ;;
  esac
  if is_render "$@"; then echo render; else echo memory; fi
}

kind="$(slot_kind "$@")"
case "$kind" in memory | render | gpu) ;; *) echo "rfs-slot: TMD_SLOT_KIND must be memory, render or gpu" >&2; exit 2 ;; esac

# A bake imports first in a memory slot, so the import's minutes never hold the GPU.
case "$(basename "$1")" in
  bake.sh | bake.cmd)
    if [ "$kind" = gpu ] && [ -z "${TMD_SLOT_NO_PREIMPORT:-}" ]; then
      TMD_SLOT_KIND=memory "$0" "$(dirname "$1")/godot.sh" --import || exit $?
    fi
    ;;
esac

want=1 suite="" tokens=()
case "$kind" in
  memory) mapfile -t tokens < <(all_tokens | grep '^token\.') ;;
  render) mapfile -t tokens < <(all_tokens) ;;
  gpu) mapfile -t tokens < <(all_tokens | grep '^render\.') ;;
esac
# Only a whole-suite run (all, quick, slow, landing or a suite folder under game/tests) runs sharded
# and takes every free token. A filter such as test_refit_board runs one Godot (13 Nov: 449 single
# files in 48 h had each held all three tokens).
whole_suite() {
  case "$1" in
    all | quick | slow | landing) return 0 ;;
    *[!a-z0-9_]* | "") return 1 ;;
  esac
  [ -d "$(dirname "$2")/../game/tests/$1" ]
}
if [[ "$(basename "$1")" == test.sh || "$(basename "$1")" == test.cmd ]]; then
  suite="${2:-all}"
  ! whole_suite "$suite" "$1" || want="$slots"
fi

cmdline="$*"
cmdline="${cmdline//$'\t'/ }"
cmdline="${cmdline//$'\n'/ }"
queued="$(date +%s)" started="" logged=""

log_line() {  # event, wait seconds, run seconds, exit code
  { [ ! -f "$log" ] || [ "$(stat -c %s "$log" 2>/dev/null || echo 0)" -lt 5000000 ]; } || mv -f "$log" "$log.1"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -Is)" "$1" "$$" "$kind" "$2" "$3" "$4" "$PWD" "$cmdline" \
    >> "$log" 2>/dev/null || true
}

# A run with nothing to do doesn't queue (13 Nov: a quarter of the imports re-imported nothing and
# each waited ~12 min first). tools/tmd.py's `precheck` says whether `godot.sh --import` or
# `test.sh SUITE` would be a no-op (no tracked file newer than the import stamp; the suite passed
# with nothing changed since); then it says so and runs nothing, exit 0, without a ticket. For a
# checkout whose tmd.py has no precheck, an explicit import still skips when its stamp is current.
# TMD_SLOT_PRECHECK=0 (or TMD_RERUN=1, which also makes tmd.py run it) always queues.
noop_run() {
  local tool="$1" tools root stamp
  tools="$(cd "$(dirname "$tool")" 2>/dev/null && pwd)" || return 1
  root="$(dirname "$tools")"
  case "${TMD_SLOT_PRECHECK:-1}:${TMD_RERUN:-${RFS_RERUN:-}}" in 0:* | *:1 | *:on | *:yes | *:true) return 1 ;; esac
  case "$(basename "$tool")" in test.sh | test.cmd | godot.sh | godot.cmd) ;; *) return 1 ;; esac
  if [ -f "$tools/tmd.py" ] && grep -q '"precheck"' "$tools/tmd.py" 2>/dev/null; then
    python3 "$tools/tmd.py" precheck "$(basename "$tool")" "${@:2}" 2>/dev/null
    return
  fi
  [[ "$(basename "$tool")" == godot.* && "${2:-}" == --import && $# -eq 2 ]] || return 1
  for stamp in "$root/game/.godot/tmd_import.stamp" "$root/game/.godot/rfs_import.stamp" ""; do
    [ -z "$stamp" ] || [ -f "$stamp" ] && break
  done
  [ -n "$stamp" ] || return 1
  [ -d "$root/game" ] && [ -z "$(cd "$root/game" && find . -path ./.godot -prune -o -type f \( -name '*.gd' -o -name '*.tscn' \
    -o -name '*.tres' -o -name '*.gdshader' -o -name '*.glb' -o -name '*.png' -o -name '*.wav' -o -name '*.ogg' \
    -o -name '*.ttf' -o -name '*.json' \) -newer "$stamp" -print -quit 2>/dev/null)" ] || return 1
  echo "rfs-slot: the import is up to date (nothing changed since its stamp)" >&2
}
if noop_run "$@"; then
  log_line noop 0 0 0
  exit 0
fi

# The ticket's key: TMD_SLOT_TICKET (or RFS_TICKET), else this folder and command, so a run that
# gave up and comes back finds its old ticket.
key="${TMD_SLOT_TICKET:-${RFS_TICKET:-}}"
key="${key//[^A-Za-z0-9_.-]/_}"
[ -n "$key" ] || key="$(printf '%s\0%s' "$PWD" "$cmdline" | sha1sum | cut -c1-12)"
attempt="$queued" name=""
old=""
for f in "$queue"/[0-9]*-"$key"; do [ -e "$f" ] && old="${f##*/}" && break; done
if [ -n "$old" ]; then
  exec 19<"$queue/$old"
  if flock -n 19; then
    lease_end="$(cat "$queue/.lease.$old" 2>/dev/null || echo 0)"
    if [ "$lease_end" -gt "$(date +%s)" ] 2>/dev/null; then
      # Back within the lease: the old place, and the wait counts from the first try.
      IFS=$'\t' read -r _ _ _ queued _ < "$queue/$old" || queued="$attempt"
      [[ "$queued" =~ ^[0-9]+$ ]] || queued="$attempt"
      name="$old"
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$want" "$$" "$queued" "$PWD" "$cmdline" > "$queue/$name"
      rm -f "$queue/.lease.$name"
      echo "rfs-slot: back in the queue at the place taken $(((attempt - queued) / 60)) min ago" >&2
    else
      rm -f "$queue/$old" "$queue/.lease.$old"
    fi
  else
    key="$key.$$"  # the same command already waiting: this one gets its own ticket
  fi
  [ -n "$name" ] || exec 19<&-
fi
if [ -z "$name" ]; then
  # Made under a dot name, locked, then renamed, so no waiter ever sees it unlocked.
  name="$((1 - first))$(printf '%019d' "$(date +%s%N)")-$key"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$want" "$$" "$queued" "$PWD" "$cmdline" > "$queue/.$name"
  exec 19<"$queue/.$name"
  flock -n 19
  mv "$queue/.$name" "$queue/$name"
fi
ticket="$queue/$name"
leased=""

on_exit() {
  local rc=$?
  [ -n "$leased" ] || rm -f "$ticket"
  [ -n "$logged" ] && return
  if [ -n "$started" ]; then
    log_line end $((started - queued)) $(($(date +%s) - started)) "$rc"
  else
    log_line left $(($(date +%s) - queued)) 0 "$rc"
  fi
}
trap on_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

held=0 told=0 next_note=0 holding=()
while :; do
  ahead_render=0 ahead_token=0 ahead=()
  while read -r other; do
    [ "$other" != "$name" ] || break
    read -r other_kind _ < "$queue/$other" 2>/dev/null || continue
    case "$other_kind" in
      render) ahead_render=1 ahead_token=1 ;;
      gpu) ahead_render=1 ;;
      *) ahead_token=1 ;;
    esac
    ahead+=("$other")
  done < <(live_tickets)

  for ((i = 0; i < ${#tokens[@]} && held < want; i++)); do
    case "${tokens[i]}" in
      render.*) [ "$ahead_render" -eq 0 ] || continue ;;
      *) [ "$ahead_token" -eq 0 ] || continue ;;
    esac
    fd=$((20 + i))
    eval "exec $fd>>\"$dir/${tokens[i]}\""
    if flock -n "$fd"; then held=$((held + 1)); holding+=("${tokens[i]}"); else eval "exec $fd>&-"; fi
  done
  [ "$held" -eq 0 ] || break

  waited=$(($(date +%s) - queued))
  if [ "$told" -eq 0 ] || [ "$waited" -ge "$next_note" ]; then
    if [ "$told" -eq 0 ]; then
      echo "rfs-slot: queued for a $kind slot, ${#ahead[@]} ahead" >&2
    else
      echo "rfs-slot: still queued after $((waited / 60)) min, ${#ahead[@]} ahead" >&2
    fi
    for other in "${ahead[@]:0:5}"; do echo "  $(describe_ticket "$other")" >&2; done
    told=1 next_note=$((waited + 600))
  fi
  if [ "$max_wait" -gt 0 ] && [ $(($(date +%s) - attempt)) -ge "$max_wait" ]; then
    # Keep the place for a while: the same command run again soon takes this ticket back.
    echo $(($(date +%s) + lease)) > "$queue/.lease.$name"
    leased=1
    echo "rfs-slot: still queued after $((waited / 60)) min (TMD_SLOT_MAX_WAIT); nothing ran. Run the same" \
      "command from this folder within $((lease / 60)) min to keep your place in the queue" \
      "(or set TMD_SLOT_TICKET=$key); rfs-slot --status shows the queue." >&2
    log_line gave-up "$waited" 0 75
    logged=1
    exit 75
  fi
  sleep 2
done

# Out of the queue: free the ticket now, so the next waiter can look.
rm -f "$ticket"
exec 19<&-
started="$(date +%s)"
for t in "${holding[@]}"; do
  printf '%s (pid %s, since %s, %s): %s\n' "$kind" "$$" "$(date +%H:%M)" "$(basename "$PWD")" "$cmdline" > "$dir/$t.who"
done
log_line start $((started - queued)) 0 ""
[ $((started - queued)) -lt 10 ] || echo "rfs-slot: got a $kind slot after $(((started - queued) / 60)) min" >&2

if [ "$want" -gt 1 ]; then
  shards="$held"
  [ "$suite" != landing ] || shards=$((held > 1 ? held - 1 : 1))
  # RFS_TEST_SHARDS too, for lanes cut before the prefix drop.
  export TMD_TEST_SHARDS="$shards" RFS_TEST_SHARDS="$shards"
  echo "rfs-slot: $held of $slots slots, $shards shards" >&2
fi
# Run the command without the lock fds, so a daemon it leaves behind (an editor, a server, a
# detached child) can't hold a slot after the run ends. The locks go when this script exits.
close=""
for ((i = 0; i < ${#tokens[@]}; i++)); do close+=" $((20 + i))>&-"; done
set +e
eval '"$@"'"$close"
exit $?
