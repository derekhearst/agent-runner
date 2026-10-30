#!/bin/bash
# rfs-slot: share the dev box's memory between RigForSilent runs. Usage: rfs-slot COMMAND [ARGS...]
# There are TMD_SLOTS tokens of TMD_SLOT_GB (default 9). By default they fill the container's
# memory cap after TMD_RESERVE_GB (default 10) for Claude sessions, agents and shells, at most 4:
# three at 40 GB before the render slot. An import of a lane far behind its cache peaks at 9-10.6 GB, and four 7 GB slots
# got the container OOM-killed at 40 GB (26 Oct). A whole-suite test run (all, quick, slow, landing or a folder) takes up to
# all the free tokens and runs that many shards; landing keeps one for the lint and net-e2e.
# Anything else (one test file, an import, a shot, a bpy build, a bake) takes one.
# Renders also have their own TMD_SLOT_RENDERS tokens (default 1) of TMD_SLOT_RENDER_GB (default 4),
# set aside from the cap before the other slots are counted: four at 48 GB, three plus the render
# slot. A shot peaks near 3 GB and spends its time on the GPU, so it shouldn't queue for an hour
# behind imports (29 Oct). A render is tools/shot.sh, or tools/godot.sh opening a scene without
# --headless, --import or --test (the periscope shots); TMD_RENDER=1 or 0 overrides. A render takes
# a render token, or any other free one; nothing else takes a render token.
# A run waits only for its first token and never for more. Tokens are lock files held by this
# script while the command runs, so they free themselves when it ends or is killed.
# Each setting also reads its old RFS_* name (RFS_SLOTS, RFS_RENDER_SLOTS, ...) when the TMD_* one
# is unset. The render count isn't TMD_RENDER_SLOTS: tools/tmd.py uses that for its own windows.
set -euo pipefail

[ $# -gt 0 ] || { echo "usage: rfs-slot COMMAND [ARGS...]" >&2; exit 2; }
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
mkdir -p "$dir"

# Whether the command draws on the GPU rather than the CPU (see the top).
is_render() {
  local force="${TMD_RENDER:-${RFS_RENDER:-}}"
  [ -z "$force" ] || { [ "$force" = 1 ]; return; }
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

want=1 suite="" tokens=()
for ((i = 0; i < slots; i++)); do tokens+=("token.$i"); done
if is_render "$@"; then
  tokens=()
  for ((i = 0; i < render_slots; i++)); do tokens+=("render.$i"); done
  for ((i = 0; i < slots; i++)); do tokens+=("token.$i"); done
elif [[ "$(basename "$1")" == test.sh || "$(basename "$1")" == test.cmd ]]; then
  suite="${2:-all}"
  [[ "$suite" == *.gd* || "$suite" == *::* || "$suite" == -* ]] || want="$slots"
fi

held=0 waited=0
while [ "$held" -eq 0 ]; do
  for ((i = 0; i < ${#tokens[@]} && held < want; i++)); do
    fd=$((20 + i))
    eval "exec $fd>>\"$dir/${tokens[i]}\""
    if flock -n "$fd"; then held=$((held + 1)); else eval "exec $fd>&-"; fi
  done
  if [ "$held" -eq 0 ]; then
    [ "$waited" -eq 1 ] || echo "rfs-slot: all ${#tokens[@]} slots for this run busy, waiting" >&2
    waited=1
    sleep 5
  fi
done

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
