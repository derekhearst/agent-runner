#!/bin/bash
# rfs-slot: share the dev box's memory between RigForSilent runs. Usage: rfs-slot COMMAND [ARGS...]
# There are RFS_SLOTS tokens (default 4, about 7 GB each: five at once got OOM-killed in the
# ~43 GB container). A whole-suite test run (all, quick, slow, landing or a folder) takes up to
# all the free tokens and runs that many shards; landing keeps one for the lint and net-e2e.
# Anything else (one test file, an import, a shot, a bpy build, a bake) takes one.
# A run waits only for its first token and never for more. Tokens are lock files, so they free
# themselves when the run and everything it started has exited.
set -euo pipefail

[ $# -gt 0 ] || { echo "usage: rfs-slot COMMAND [ARGS...]" >&2; exit 2; }
slots="${RFS_SLOTS:-4}"
dir="${RFS_SLOT_DIR:-$HOME/.rfs-slots}"
mkdir -p "$dir"

want=1 suite=""
if [[ "$(basename "$1")" == test.sh || "$(basename "$1")" == test.cmd ]]; then
  suite="${2:-all}"
  [[ "$suite" == *.gd* || "$suite" == *::* || "$suite" == -* ]] || want="$slots"
fi

# Lock fds 20.. are inherited by the command (exec keeps them), so the tokens are held until it ends.
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
exec "$@"
