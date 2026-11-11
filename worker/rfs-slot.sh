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
max_wait="${TMD_SLOT_MAX_WAIT:-60}"  # minutes, or seconds with an s (30s)
if [[ "$max_wait" == *s ]]; then max_wait="${max_wait%s}"; else max_wait=$((max_wait * 60)); fi
mkdir -p "$queue"

all_tokens() {
  local i
  for ((i = 0; i < render_slots; i++)); do echo "render.$i"; done
  for ((i = 0; i < slots; i++)); do echo "token.$i"; done
}

# The live tickets' file names, oldest first; drops the ones whose run has died (nobody holds
# their lock). Ticket names are a priority digit and a fixed-width time, so they sort as text.
live_tickets() {
  local name
  while read -r name; do
    [ -n "$name" ] || continue
    if flock -n "$queue/$name" true 2>/dev/null; then rm -f "$queue/$name"; else echo "$name"; fi
  done < <(cd "$queue" && ls -1 | grep '^[0-9]' | LC_ALL=C sort)
}

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
  local names=() name
  mapfile -t names < <(live_tickets)
  echo "queue (${#names[@]}, oldest first):"
  for name in "${names[@]}"; do echo "  $(describe_ticket "$name")"; done
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
if [[ "$(basename "$1")" == test.sh || "$(basename "$1")" == test.cmd ]]; then
  suite="${2:-all}"
  [[ "$suite" == *.gd* || "$suite" == *::* || "$suite" == -* ]] || want="$slots"
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

# The ticket: made under a dot name, locked, then renamed, so no waiter ever sees it unlocked.
name="$((1 - first))$(printf '%019d' "$(date +%s%N)")-$$"
ticket="$queue/$name"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$want" "$$" "$queued" "$PWD" "$cmdline" > "$queue/.$name"
exec 19<"$queue/.$name"
flock -n 19
mv "$queue/.$name" "$ticket"

on_exit() {
  local rc=$?
  rm -f "$ticket"
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
  if [ "$max_wait" -gt 0 ] && [ "$waited" -ge "$max_wait" ]; then
    echo "rfs-slot: still queued after $((waited / 60)) min (TMD_SLOT_MAX_WAIT); nothing ran. Run it again" \
      "later, or see who holds the slots with rfs-slot --status." >&2
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
