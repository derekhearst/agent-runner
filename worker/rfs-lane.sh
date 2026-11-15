#!/bin/bash
# rfs-lane: one git worktree per RigForSilent lane, cheap to make and never left behind.
#   rfs-lane new LANE [BASE] [--branch NAME]
#                              ~/work/rfs-LANE on branch claude/rfs-LANE, or NAME (the remote branch
#                              if it exists, else a new one from BASE, default origin/main). The Godot
#                              cache and the LFS files are copy-on-write clones of the main
#                              checkout's, so a new lane costs a few GB rather than ~20.
#   rfs-lane seed [--if-stale] keeps ~/work/.rfs-seed, a checkout of origin/main with its Godot
#                              import done, and publishes its cache for `new` to clone. Run it after
#                              a landing (the dev box does it hourly when main has moved). Its import
#                              queues ahead of other runs (rfs-slot --first).
#   rfs-lane done LANE         removes the worktree once it is clean, pushed and in main.
#   rfs-lane prune             `done` for every lane idle TMD_SWEEP_IDLE_H hours (24) that no
#                              process is using, and for clean, fully pushed lanes not in main
#                              (concept branches) idle TMD_SWEEP_PUSHED_IDLE_D days (7): their
#                              branch stays on GitHub. Lists the ones it keeps and why.
#   rfs-lane sweep [--dry-run] [--urgent] [--if-low]
#                              prune, then clear scratch older than TMD_SWEEP_SCRATCH_D days (3):
#                              Claude session folders and loose files in /tmp. Prints what it
#                              removed and the space freed. Also ~/work/rfs-share/<lane> folders
#                              untouched TMD_SWEEP_SHARE_D days (14) whose lane is gone. --urgent (or free space under
#                              TMD_DISK_LOW_GB, 150) cuts the idle times to 6 hours and 1 day;
#                              --if-low does nothing unless space is under TMD_DISK_LOW_GB. The box
#                              runs it hourly, `--if-low` every 10 min, and rfs-slot before heavy runs.
#   rfs-lane list              the lanes with their state.
# New lanes only ever clone a published seed cache (~/work/.rfs-seed-caches/current): the last
# seed import that finished. A refresh imports in ~/work/.rfs-seed and publishes a copy-on-write
# copy only when it ends, so lanes made meanwhile still get the last good cache. Until 11 Nov a
# lane made mid-refresh got the main checkout's weeks-old cache and reimported ~3,500 assets.
# TMD_MAIN_CHECKOUT (or the old RFS_MAIN) is the main checkout (default ~/work/RigForSilent). `done --force` skips the in-main
# check (an abandoned lane) but never deletes uncommitted or unpushed work.
# Godot rewrites .import, .uid and .unwrap_cache files on every import, so those (and untracked
# *.log files at the lane root, kept in ~/work/runlogs/removed) don't count as uncommitted work:
# until 15 Nov they kept nearly every lane alive and the Apps pool filled (ENOSPC).
# A lane with a LANE_KEEP file is never removed. A copy of main for before shots (-before, -main,
# -base) whose only changes are added files is removed with them archived in runlogs/removed.
# Removals are logged in ~/work/.rfs-lane-removed.log with the commit, to recreate one if needed.
set -euo pipefail
# TMD_REFLINK=auto lets the copies below fall back to plain copies (tests on filesystems without reflinks).

main="${TMD_MAIN_CHECKOUT:-${RFS_MAIN:-$HOME/work/RigForSilent}}"
root="$(dirname "$main")"
git_main() { git -C "$main" "$@"; }

lane_dir() { echo "$root/rfs-$1"; }
seed="$root/.rfs-seed"
seed_commit="$root/.rfs-seed.commit"
caches="$root/.rfs-seed-caches"  # published seed caches: <time>-<commit>/.godot, `current` -> the newest

# LFS files as reflinks of the objects the repo already has (downloading what's missing).
lfs_files() {
  git -C "$1" lfs pull >/dev/null && git -C "$1" lfs dedup >/dev/null || echo "lfs dedup skipped" >&2
}

# Files git calls modified only because the index still holds the LFS pointer's size: the
# worktree is checked out without smudging, then `lfs pull` and `dedup` rewrite the files with
# the same content. Re-record those (nothing gets staged: they clean to the committed blobs).
fix_index() {
  local dir="$1"
  comm -23 <(git -C "$dir" ls-files -m | sort -u) <(git -C "$dir" diff --name-only | sort -u) \
    | tr '\n' '\0' | git -C "$dir" add --renormalize --pathspec-from-file=- --pathspec-file-nul 2>/dev/null \
    || true
}

# The folder of the newest published seed cache (holding .godot and commit), or nothing.
published() {
  local d
  d="$(readlink -f "$caches/current" 2>/dev/null || true)"
  [ -n "$d" ] && [ -d "$d/.godot" ] && [ -s "$d/commit" ] && echo "$d"
}

# Publishes the seed's finished import: a copy-on-write copy under $caches, then `current` is
# switched to it in one rename, so a lane copying the old one is never cut short. Old copies are
# removed once no lane is copying (they hold $caches/.lock shared while they copy).
publish() {
  local commit="$1" new old
  mkdir -p "$caches"
  new="$caches/$(date +%Y%m%d-%H%M%S)-${commit:0:9}"
  if ! { mkdir -p "$new.part" && cp -a --reflink="${TMD_REFLINK:-always}" "$seed/game/.godot" "$new.part/.godot"; }; then
    rm -rf "$new.part"
    echo "rfs-lane: couldn't copy the seed's cache; lanes keep the last published one" >&2
    return 1
  fi
  echo "$commit" > "$new.part/commit"
  mv "$new.part" "$new"
  ln -sfn "$(basename "$new")" "$caches/current.new"
  mv -T "$caches/current.new" "$caches/current"
  (
    flock -n -x 9 || exit 0
    for old in "$caches"/*; do
      [ "$old" != "$new" ] && [ "$(basename "$old")" != current ] && rm -rf "$old"
    done
  ) 9>"$caches/.lock"
  echo "published the seed cache at ${commit:0:9}"
}

# The warm import cache a new lane starts from: the newest published seed cache. Never the main
# checkout's: it matches whatever that checkout last imported (25 Oct on 11 Nov). With nothing
# published yet (just after the change that brought publishing), a refresh that is running is
# waited for, up to TMD_SEED_WAIT minutes (60), and then an imported seed counts.
cache_source() {
  local p
  p="$(published)" && { echo "$p"; return; }
  [ -d "$seed/game/.godot" ] || return 1
  (
    exec 9>"$root/.rfs-seed.lock"
    flock -n 9 || { echo "waiting for the seed refresh to finish" >&2; flock -w $((${TMD_SEED_WAIT:-60} * 60)) 9; }
  ) || return 1
  p="$(published)" && { echo "$p"; return; }
  [ -s "$seed_commit" ] && echo "$seed/game"
}

# The lane's changes that are real work: everything but Godot's import churn and root logs.
real_changes() {
  git -C "$1" status --porcelain | grep -Ev '\.(import|uid|unwrap_cache)$' | grep -Ev '^\?\? [^/]+\.log$' || true
}

# Why a lane can't go yet (empty when it can). $2 = "force" skips the in-main check.
blocker() {
  local dir="$1" force="${2:-}" branch
  branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD)"
  fix_index "$dir"
  [ ! -e "$dir/LANE_KEEP" ] || { echo "LANE_KEEP"; return; }
  local real
  real="$(real_changes "$dir")"
  if [ -n "$real" ]; then
    # A copy of main kept for before shots (rfs-X-before, -main, -base): files it added (shot rigs)
    # are archived on removal rather than keeping it forever. Edits to tracked files still keep it.
    if [[ "$(basename "$dir")" =~ -(before|main|base|mainref|maincheck)$ ]] && ! grep -qv '^??' <<<"$real" \
      && git -C "$dir" merge-base --is-ancestor HEAD origin/main; then
      return
    fi
    echo "uncommitted changes"; return
  fi
  # In main: nothing to lose, pushed or not (a -before copy, a landed lane).
  [ "$force" != force ] && git -C "$dir" merge-base --is-ancestor HEAD origin/main && return
  git -C "$dir" rev-parse -q --verify "origin/$branch" >/dev/null || { echo "branch never pushed"; return; }
  [ "$(git -C "$dir" rev-list --count "origin/$branch..HEAD")" = 0 ] || { echo "unpushed commits"; return; }
  [ "$force" = force ] && return
  # Squash merges leave no ancestry; ask GitHub, and only when the merged PR ends at this commit
  # (or later), so commits pushed after the merge are kept.
  local head oid
  head="$(git -C "$dir" rev-parse HEAD)"
  if command -v gh >/dev/null && [ "$branch" != HEAD ]; then
    for oid in $(cd "$dir" && gh pr list --head "$branch" --state merged --json headRefOid -q '.[].headRefOid' 2>/dev/null); do
      [ "$oid" = "$head" ] && return
      git -C "$dir" merge-base --is-ancestor HEAD "$oid" 2>/dev/null && return
    done
  fi
  echo "not in main yet"
}

# Paths that running processes have open or sit in (one /proc scan per prune).
busy_list=""
scan_busy() {
  busy_list="$(mktemp)"
  { find /proc/[0-9]*/cwd -maxdepth 0 -printf '%l\n'; find /proc/[0-9]*/fd -mindepth 1 -maxdepth 1 -printf '%l\n'; } \
    2>/dev/null | sort -u > "$busy_list" || true
  cat "$HOME"/.rfs-slots/*.who 2>/dev/null >> "$busy_list" || true
}
in_use() {
  [ -n "$busy_list" ] || return 1
  awk -v p="$1" -v who=", $(basename "$1")):" 'index($0, p "/") == 1 || $0 == p || index($0, who) { f = 1; exit } END { exit !f }' "$busy_list"
}

# Why a lane must stay although it is landed: in use, or touched within $2 hours (a commit or
# checkout that moved HEAD, or a file outside the import cache). A reset that left HEAD where it
# was doesn't count: one ran across every lane on 15 Nov.
recent() {
  local dir="$1" mins=$(($2 * 60)) moved
  in_use "$dir" && { echo "in use by a running process"; return; }
  moved="$(awk '$1 != $2 { t = $0 } END { print t }' "$(git -C "$dir" rev-parse --absolute-git-dir)/logs/HEAD" 2>/dev/null \
    | sed -E 's/.*> ([0-9]+) [-+][0-9]{4}\t.*/\1/')"
  if { [[ "$moved" =~ ^[0-9]+$ ]] && [ $(($(date +%s) - moved)) -lt $((mins * 60)) ]; } \
    || [ -n "$(find "$dir" -mindepth 1 \( -path "$dir/game/.godot" -o -name .git \) -prune -o -mmin "-$mins" -print -quit 2>/dev/null)" ]; then
    echo "used within ${2} h"
  fi
}

remove() {
  local dir="$1" branch head logs
  branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD)" head="$(git -C "$dir" rev-parse HEAD)"
  logs="$(cd "$dir" && git status --porcelain | sed -n 's/^?? \([^/]*\.log\)$/\1/p')"
  # Added files a copy of main kept (see blocker): archived beside its logs.
  local added
  added="$(real_changes "$dir" | sed -n 's/^?? //p')"
  if [ -n "$added" ]; then
    mkdir -p "$root/runlogs/removed/$(basename "$dir")"
    (cd "$dir" && echo "$added" | tar -czf "$root/runlogs/removed/$(basename "$dir")/added.tgz" -T -) \
      || { echo "couldn't archive what $dir added; kept" >&2; return 1; }
  fi
  if [ -n "$logs" ]; then
    mkdir -p "$root/runlogs/removed/$(basename "$dir")"
    (cd "$dir" && echo "$logs" | xargs -d '\n' mv -t "$root/runlogs/removed/$(basename "$dir")")
  fi
  git_main worktree remove --force "$dir"
  [ "$branch" = HEAD ] || git_main branch -D "$branch" >/dev/null 2>&1 || true
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$dir")" "$branch" "$head" >> "$root/.rfs-lane-removed.log"
  echo "removed $dir ($branch at ${head:0:9})"
}

free_gb() { df -P -BG "$root" | awk 'NR == 2 { sub("G", "", $4); print $4 }'; }

# The lanes that can go: removed (or listed, with $2 = dry), the rest listed with the reason.
prune_lanes() {
  local idle="$1" dry="${2:-}" dir why
  git_main fetch -q origin
  git_main worktree prune
  scan_busy
  for dir in "$root"/rfs-*; do
    [ -e "$dir/.git" ] || continue
    why="$(blocker "$dir")"
    if [ -z "$why" ]; then
      why="$(recent "$dir" "$idle")"
    elif [ "$why" = "not in main yet" ]; then
      # Clean and all on GitHub (concept branches that never merge): goes after a week idle.
      why="$(recent "$dir" $((${TMD_SWEEP_PUSHED_IDLE_D:-7} * 24)) | sed 's/^used/not in main yet, used/')"
    fi
    if [ -n "$why" ]; then
      echo "kept $dir: $why"
    elif [ -n "$dry" ]; then
      echo "would remove $dir ($(git -C "$dir" rev-parse --abbrev-ref HEAD))"
    else
      remove "$dir" || echo "couldn't remove $dir" >&2
    fi
  done
  rm -f "$busy_list"; busy_list=""
}

# Scratch older than $1 days that nothing has open: Claude Code's per-session folders and loose
# files in /tmp (renders, logs, Blender and mktemp folders; TMD_SWEEP_TMP in tests). The X server's
# and live sockets stay.
sweep_scratch() {
  local days="$1" dry="${2:-}" mins=$(($1 * 1440)) e t="${TMD_SWEEP_TMP:-/tmp}"
  scan_busy
  {
    for e in "$t"/claude-*/*/* "$t"/claude-*/*; do
      case "$e" in */bundled-skills | */bundled-skills/* | */bash-edit-diff | "$t"/claude-*/-*[!/]) ;; *) echo "$e" ;; esac
    done
    find "$t" -mindepth 1 -maxdepth 1 -user "$(id -u)" ! -name 'claude-*' ! -name '.X*' \
      ! -name 'cc-socks' ! -name 'pulse-*' ! -name 'tmux-*' ! -name 'ssh-*' 2>/dev/null
  } | sort -u | while read -r e; do
    [ -e "$e" ] || continue
    in_use "$e" && continue
    [ -z "$(find "$e" -mmin "-$mins" -print -quit 2>/dev/null)" ] || continue
    if [ -n "$dry" ]; then echo "would clear $e"; else rm -rf "$e" && echo "cleared $e"; fi
  done
  rm -f "$busy_list"; busy_list=""
}

# ~/work/rfs-share/<lane>: renders and logs sessions keep outside their lane (what gets reviewed is
# pushed to pr-shots). A folder goes once nothing in it changed for TMD_SWEEP_SHARE_D days (14) and
# its lane is gone. Until 15 Nov nothing cleared it (39 GB).
sweep_share() {
  local days="$1" dry="${2:-}" e
  [ -d "$root/rfs-share" ] || return 0
  scan_busy
  for e in "$root"/rfs-share/*; do
    [ -e "$e" ] || continue
    [ ! -e "$root/rfs-$(basename "$e")" ] || continue
    in_use "$e" && continue
    [ -z "$(find "$e" -mmin "-$((days * 1440))" -print -quit 2>/dev/null)" ] || continue
    if [ -n "$dry" ]; then echo "would clear $e"; else rm -rf "$e" && echo "cleared $e"; fi
  done
  rm -f "$busy_list"; busy_list=""
}

cmd="${1:-}"; shift || true
case "$cmd" in
  new)
    lane="${1:?usage: rfs-lane new LANE [BASE] [--branch NAME]}" base="origin/main" branch="claude/rfs-$lane"
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --branch) branch="${2:?--branch needs a name}"; shift 2 ;;
        *) base="$1"; shift ;;
      esac
    done
    dir="$(lane_dir "$lane")"
    [ ! -e "$dir" ] || { echo "$dir already exists" >&2; exit 1; }
    git_main fetch -q origin main
    git_main fetch -q origin "$branch" 2>/dev/null || true
    if git_main rev-parse -q --verify "origin/$branch" >/dev/null; then
      GIT_LFS_SKIP_SMUDGE=1 git_main worktree add -B "$branch" "$dir" "origin/$branch"
    else
      GIT_LFS_SKIP_SMUDGE=1 git_main worktree add -b "$branch" "$dir" "$base"
    fi
    git -C "$dir" branch -q --set-upstream-to="origin/$branch" 2>/dev/null || true
    # LFS files and the import cache as reflinks of what the main checkout already has.
    lfs_files "$dir"
    fix_index "$dir"
    if [ ! -e "$dir/game/.godot" ]; then
      mkdir -p "$caches"
      (
        flock -s 9  # keeps `seed` from removing the copy we read
        if src="$(cache_source)"; then
          echo "import cache from the seed at $(cut -c1-9 "$src/commit" 2>/dev/null || cut -c1-9 "$seed_commit")"
          cp -a --reflink="${TMD_REFLINK:-always}" "$src/.godot" "$dir/game/.godot" \
            || { rm -rf "$dir/game/.godot"; echo "no reflink copy of game/.godot; the first import fills it" >&2; }
        else
          echo "rfs-lane: no seed cache yet, so this lane's first import is a full one (an hour or" \
            "more). Run \`rfs-lane seed\` first if you can wait for it." >&2
        fi
      ) 9>"$caches/.lock"
    fi
    echo "$dir on $branch"
    ;;
  seed)
    exec 9>"$root/.rfs-seed.lock"
    flock -n 9 || { echo "a seed refresh is already running" >&2; exit 0; }
    git_main fetch -q origin main
    target="$(git_main rev-parse origin/main)"
    # A seed imported before publishing existed: publish it as it is first.
    if ! published >/dev/null && [ -s "$seed_commit" ] && [ -d "$seed/game/.godot" ]; then
      publish "$(cat "$seed_commit")" || true
    fi
    if [ "${1:-}" = --if-stale ] && [ "$(cat "$seed_commit" 2>/dev/null)" = "$target" ]; then exit 0; fi
    rm -f "$seed_commit"
    if [ ! -e "$seed/.git" ]; then
      GIT_LFS_SKIP_SMUDGE=1 git_main worktree add -q --detach "$seed" "$target"
      # Start from a published cache (else the main checkout's) so the import only redoes what differs.
      from="$(published || echo "$main/game")"
      [ ! -d "$from/.godot" ] || cp -a --reflink="${TMD_REFLINK:-always}" "$from/.godot" "$seed/game/.godot" || true
    else
      GIT_LFS_SKIP_SMUDGE=1 git -C "$seed" checkout -q --force --detach "$target"
      git -C "$seed" clean -q -fd -e game/.godot
    fi
    lfs_files "$seed"
    fix_index "$seed"
    echo "importing the seed at $(git -C "$seed" log -1 --format='%h %s')"
    # A first seed import can redo ~1,000 assets, past rfs.py's 30 min default; Godot keeps what
    # it finished, so a timed-out import resumes on the next refresh.
    # Ahead of every other queued run (rfs-slot --first), and never giving up its place: lanes
    # made while it waits still get the last published cache, but they drift further behind main.
    (cd "$seed" && t="${TMD_SEED_TIMEOUT:-${RFS_SEED_TIMEOUT:-120}}" \
      && TMD_TIMEOUT="$t" RFS_TIMEOUT="$t" TMD_SLOT_MAX_WAIT=0 rfs-slot --first tools/godot.sh --import)
    echo "$target" > "$seed_commit"
    publish "$target" || true
    echo "seed ready at ${target:0:9}"
    ;;
  done)
    lane="${1:?usage: rfs-lane done LANE [--force]}"
    dir="$(lane_dir "$lane")"
    [ -d "$dir" ] || { echo "no lane at $dir" >&2; exit 1; }
    git_main fetch -q origin
    why="$(blocker "$dir" "$([ "${2:-}" = --force ] && echo force)")"
    [ -z "$why" ] || { echo "kept $dir: $why" >&2; exit 1; }
    remove "$dir"
    ;;
  prune)
    prune_lanes "${TMD_SWEEP_IDLE_H:-24}"
    ;;
  list)
    git_main fetch -q origin
    git_main worktree prune
    for dir in "$root"/rfs-*; do
      [ -e "$dir/.git" ] || continue
      why="$(blocker "$dir")"
      echo "$(basename "$dir")  $(git -C "$dir" rev-parse --abbrev-ref HEAD)  ${why:-landed}"
    done
    ;;
  sweep)
    dry="" urgent="" if_low=""
    for a in "$@"; do
      case "$a" in --dry-run) dry=1 ;; --urgent) urgent=1 ;; --if-low) if_low=1 ;; *) echo "unknown: $a" >&2; exit 2 ;; esac
    done
    low="${TMD_DISK_LOW_GB:-150}" before="$(free_gb)"
    [ "$before" -lt "$low" ] && urgent=1
    [ -z "$if_low" ] || [ -n "$urgent" ] || exit 0
    # One sweep at a time; a second one (rfs-slot's, the timer's) leaves it to the first.
    exec 8>"$root/.rfs-sweep.lock"
    flock -n 8 || { echo "a sweep is already running" >&2; exit 0; }
    if [ -n "$urgent" ]; then
      echo "rfs-lane sweep: !!! ${before} GB free on the Apps pool (low is ${low} GB): removing idle landed lanes" \
        "after ${TMD_SWEEP_URGENT_IDLE_H:-6} h and scratch after 1 day. Commit and push lane work now. !!!" >&2
      idle="${TMD_SWEEP_URGENT_IDLE_H:-6}" days=1
    else
      idle="${TMD_SWEEP_IDLE_H:-24}" days="${TMD_SWEEP_SCRATCH_D:-3}"
    fi
    echo "sweep $(date -u +%FT%TZ): ${before} GB free"
    prune_lanes "$idle" "$dry"
    sweep_scratch "$days" "$dry"
    sweep_share "${TMD_SWEEP_SHARE_D:-14}" "$dry"
    sync; sleep 5  # ZFS frees asynchronously
    echo "sweep done: ${before} GB -> $(free_gb) GB free"
    ;;
  *)
    sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
