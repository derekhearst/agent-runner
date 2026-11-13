#!/bin/bash
# Tests for rfs-slot.sh: the first-come queue, --first, the kinds of run, giving up, the log and
# the bake's import. Run: bash worker/test_rfs_slot.sh (no root, no Godot; about 40 s).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
slot="$here/rfs-slot.sh"
fails=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fresh() {  # a clean slot folder: one memory token and one render token
  rm -rf "$tmp/slots" "$tmp/out"
  mkdir -p "$tmp/slots" "$tmp/out"
  export TMD_SLOT_DIR="$tmp/slots" TMD_SLOTS=1 TMD_SLOT_RENDERS=1 TMD_SLOT_MAX_WAIT=0
  unset TMD_SLOT_KIND TMD_RENDER RFS_RENDER
}
check() {  # name, expected, actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2], got [$3]"; fails=$((fails + 1)); fi
}
note() { echo "$1" >> "$tmp/out/order"; }
export -f note
export tmp

# --help and --status queue nothing.
fresh
"$slot" --help > /dev/null
"$slot" --status > /dev/null
check "help queues nothing" "" "$(ls -A "$tmp/slots/queue"; cat "$tmp/slots/slot.log" 2>/dev/null)"

# Waiters run in the order they came; --first goes ahead of them.
fresh
"$slot" sleep 3 &
sleep 0.5
"$slot" bash -c 'note B' 2> /dev/null &
sleep 0.5
"$slot" bash -c 'note C' 2> /dev/null &
sleep 0.5
"$slot" --first bash -c 'note D' 2> /dev/null &
wait
check "first come first served, --first ahead" "D B C" "$(tr '\n' ' ' < "$tmp/out/order" | sed 's/ $//')"

# A shot doesn't queue behind memory runs: it takes the render token.
fresh
"$slot" sleep 3 &
sleep 0.5
"$slot" bash -c 'note memory' 2> /dev/null &
sleep 0.5
TMD_SLOT_KIND=render "$slot" bash -c 'note render' 2> /dev/null
wait
check "render passes queued memory runs" "render memory" "$(tr '\n' ' ' < "$tmp/out/order" | sed 's/ $//')"

# A GPU run takes only the render token: a second one waits though a memory token is free.
fresh
TMD_SLOT_KIND=gpu "$slot" sleep 2 &
sleep 0.5
start=$(date +%s)
TMD_SLOT_KIND=gpu "$slot" true 2> /dev/null
check "one GPU run at a time" "1" "$([ $(($(date +%s) - start)) -ge 1 ] && echo 1 || echo 0)"
start=$(date +%s)
"$slot" true
check "memory run beside a GPU run" "1" "$([ $(($(date +%s) - start)) -lt 1 ] && echo 1 || echo 0)"
wait
check "bpy.sh is a GPU run" "gpu" "$(cd "$tmp" && mkdir -p tools && printf '#!/bin/sh\n' > tools/bpy.sh && chmod +x tools/bpy.sh \
  && "$slot" tools/bpy.sh x.py && tail -n 1 "$tmp/slots/slot.log" | cut -f4)"

# A waiter gives up with 75 after TMD_SLOT_MAX_WAIT and logs it; the slot's holder is shown.
fresh
"$slot" sleep 4 &
sleep 0.5
check "status names the holder" "1" "$("$slot" --status | grep -c 'token.0  busy: memory.*sleep 4')"
TMD_SLOT_MAX_WAIT=2s "$slot" true 2> "$tmp/out/err"
check "gives up with 75" "75" "$?"
check "says still queued" "1" "$(grep -c 'still queued' "$tmp/out/err")"
check "logs gave-up" "1" "$(grep -c $'\tgave-up\t' "$tmp/slots/slot.log")"
wait

# A run that gave up keeps its place for TMD_SLOT_LEASE: back in time from the same folder with the
# same command, it goes before later arrivals, and its wait counts from its first try.
fresh
"$slot" sleep 5 &
sleep 0.5
(cd "$tmp/out" && TMD_SLOT_MAX_WAIT=1s "$slot" bash -c 'note A') 2> /dev/null
check "gave-up ticket keeps its place" "1" "$("$slot" --status | grep -c '(left)')"
"$slot" bash -c 'note B' 2> /dev/null &
sleep 0.5
(cd "$tmp/out" && "$slot" bash -c 'note A') 2> "$tmp/out/err" &
wait
check "back within the lease goes first" "A B" "$(tr '\n' ' ' < "$tmp/out/order" | sed 's/ $//')"
check "says it is back in its place" "1" "$(grep -c 'back in the queue' "$tmp/out/err")"
check "wait counted from the first try" "1" \
  "$(awk -F'\t' '$2 == "start" && $9 == "bash -c note A" { print ($5 >= 4) }' "$tmp/slots/slot.log")"

# A ticket on lease holds nobody back, and an expired lease is a fresh start.
fresh
"$slot" sleep 2 &
sleep 0.5
(cd "$tmp/out" && TMD_SLOT_MAX_WAIT=1s TMD_SLOT_LEASE=6s "$slot" bash -c 'note A') 2> /dev/null
start=$(date +%s)
"$slot" true
check "a leased ticket holds nobody back" "1" "$([ $(($(date +%s) - start)) -le 2 ] && echo 1 || echo 0)"
wait
sleep 6
(cd "$tmp/out" && "$slot" bash -c 'note A') 2> "$tmp/out/err"
check "an expired lease starts over" "0" "$(grep -c 'back in the queue' "$tmp/out/err")"

# A ticket whose run died is dropped and doesn't hold the queue.
fresh
mkdir -p "$tmp/slots/queue"
printf 'memory\t1\t1\t0\t/x\tdead\n' > "$tmp/slots/queue/00000000000000000001-1"
TMD_SLOT_MAX_WAIT=3s "$slot" true 2> /dev/null
check "dead ticket dropped" "0 " "$? $(ls -A "$tmp/slots/queue")"

# The log has a start and an end line with the wait, run time and exit code.
fresh
"$slot" bash -c 'exit 3'
check "end logs the exit code" "3" "$(grep $'\tend\t' "$tmp/slots/slot.log" | cut -f7)"
check "start logged" "1" "$(grep -c $'\tstart\t' "$tmp/slots/slot.log")"

# A bake imports in a memory slot first, then bakes in the render slot.
fresh
mkdir -p "$tmp/game/tools"
printf '#!/bin/bash\nnote "import $*"\n' > "$tmp/game/tools/godot.sh"
printf '#!/bin/bash\nnote bake\n' > "$tmp/game/tools/bake.sh"
chmod +x "$tmp/game/tools/"*.sh
(cd "$tmp/game" && "$slot" tools/bake.sh)
check "bake imports first" "import --import bake" "$(tr '\n' ' ' < "$tmp/out/order" | sed 's/ $//')"
check "import as memory, bake as gpu" "memory gpu" "$(grep $'\tend\t' "$tmp/slots/slot.log" | cut -f4 | tr '\n' ' ' | sed 's/ $//')"

# A command's own --help runs without a slot.
fresh
"$slot" bash --help > /dev/null 2>&1
check "command help takes no slot" "" "$(cat "$tmp/slots/slot.log" 2>/dev/null)"

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
