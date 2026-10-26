#!/bin/bash
# rfs-slot: share the dev box's memory between RigForSilent runs. Usage: rfs-slot COMMAND [ARGS...]
# There are RFS_SLOTS tokens of RFS_SLOT_GB (default 9). By default they fill the container's
# memory cap after RFS_RESERVE_GB (default 10) for Claude sessions, agents and shells, at most 4:
# three at 40 GB. An import of a lane far behind its cache peaks at 9-10.6 GB, and four 7 GB slots
# got the container OOM-killed at 40 GB (26 Oct). A whole-suite test run (all, quick, slow, landing or a folder) takes up to
# all the free tokens and runs that many shards; landing keeps one for the lint and net-e2e.
# Anything else (one test file, an import, a shot, a bpy build, a bake) takes one.
# A run waits only for its first token and never for more. Tokens are lock files held by this
# script while the command runs, so they free themselves when it ends or is killed.
set -euo pipefail

[ $# -gt 0 ] || { echo "usage: rfs-slot COMMAND [ARGS...]" >&2; exit 2; }
# The cgroup's cap in GB (v2, then v1), or empty when there is none.
cap_gb() {
  local raw
  raw="$(cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || true)"
  [[ "$raw" =~ ^[0-9]+$ ]] && [ "$raw" -lt $((1 << 50)) ] && echo $((raw / 1024 / 1024 / 1024))
}
slots="${RFS_SLOTS:-}"
if [ -z "$slots" ]; then
  cap="$(cap_gb || true)" slots=4
  if [ -n "$cap" ]; then
    slots=$(((cap - ${RFS_RESERVE_GB:-10}) / ${RFS_SLOT_GB:-9}))
    [ "$slots" -le 4 ] || slots=4
    [ "$slots" -ge 1 ] || slots=1
  fi
fi
dir="${RFS_SLOT_DIR:-$HOME/.rfs-slots}"
mkdir -p "$dir"

want=1 suite=""
if [[ "$(basename "$1")" == test.sh || "$(basename "$1")" == test.cmd ]]; then
  suite="${2:-all}"
  [[ "$suite" == *.gd* || "$suite" == *::* || "$suite" == -* ]] || want="$slots"
fi

held=0 waited=0
while [ "$held" -eq 0 ]; do
  for ((i = 0; i < slots && held < want; i++)); do
    fd=$((20 + i))
    eval "exec $fd>>\"$dir/token.$i\""
    if flock -n "$fd"; then held=$((held + 1)); else eval "exec $fd>&-"; fi
  done
  if [ "$held" -eq 0 ]; then
    [ "$waited" -eq 1 ] || echo "rfs-slot: all $slots slots busy, waiting" >&2
    waited=1
    sleep 5
  fi
done

if [ "$want" -gt 1 ]; then
  shards="$held"
  [ "$suite" != landing ] || shards=$((held > 1 ? held - 1 : 1))
  export RFS_TEST_SHARDS="$shards"
  echo "rfs-slot: $held of $slots slots, $shards shards" >&2
fi
# Run the command without the lock fds, so a daemon it leaves behind (an editor, a server, a
# detached child) can't hold a slot after the run ends. The locks go when this script exits.
close=""
for ((i = 0; i < slots; i++)); do close+=" $((20 + i))>&-"; done
set +e
eval '"$@"'"$close"
exit $?
