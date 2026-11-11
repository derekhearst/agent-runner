#!/bin/bash
# Tests for rfs-lane.sh's seed cache: a lane never gets the main checkout's cache, a lane made
# during a seed refresh gets the last published one, and a refresh publishes when it ends.
# Run: bash worker/test_rfs_lane.sh (needs git and git-lfs; no Godot: a fake tools/godot.sh
# "imports" by writing game/.godot/stamp).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
check() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2], got [$3]"; fails=$((fails + 1)); fi
}

# rfs-slot and rfs-lane on PATH, as in the image.
mkdir -p "$tmp/bin"
ln -s "$here/rfs-slot.sh" "$tmp/bin/rfs-slot"
ln -s "$here/rfs-lane.sh" "$tmp/bin/rfs-lane"
export TMD_REFLINK=auto PATH="$tmp/bin:$PATH" HOME="$tmp/home" TMD_SLOT_DIR="$tmp/slots" TMD_SLOTS=1 TMD_SLOT_RENDERS=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME/work"
git config --global init.defaultBranch main
git config --global advice.detachedHead false

# origin with a fake tools/godot.sh whose import stamps the cache with the commit (after a pause
# when TEST_IMPORT_PAUSE is set, so a lane can be made mid-refresh).
git init -q "$tmp/src" && cd "$tmp/src"
mkdir -p tools game
cat > tools/godot.sh <<'EOF'
#!/bin/bash
[ -z "${TEST_IMPORT_PAUSE:-}" ] || sleep "$TEST_IMPORT_PAUSE"
mkdir -p game/.godot && git rev-parse --short HEAD > game/.godot/stamp
EOF
chmod +x tools/godot.sh
echo .godot > game/.gitignore
echo 1 > game/a.txt
git add -A && git commit -qm one
git clone -q --bare "$tmp/src" "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$HOME/work/RigForSilent"
main="$HOME/work/RigForSilent"
mkdir -p "$main/game/.godot" && echo stale-main > "$main/game/.godot/stamp"

# No seed at all: the lane gets no cache, never the main checkout's.
rfs-lane new a > "$tmp/out" 2>&1
check "no seed: not main's cache" "absent" "$(cat "$HOME/work/rfs-a/game/.godot/stamp" 2>/dev/null || echo absent)"

# A seed refresh publishes; a new lane gets it.
rfs-lane seed > "$tmp/out" 2>&1
one="$(git -C "$tmp/src" rev-parse --short HEAD)"
check "seed published" "$one" "$(cat "$HOME/work/.rfs-seed-caches/current/.godot/stamp" 2>/dev/null)"
rfs-lane new b > "$tmp/out" 2>&1
check "lane gets the published seed" "$one" "$(cat "$HOME/work/rfs-b/game/.godot/stamp" 2>/dev/null)"

# main moves; during the refresh a new lane still gets the last published cache, at once.
cd "$tmp/src" && echo 2 > game/a.txt && git commit -qam two && git push -q "$tmp/origin.git" main
two="$(git -C "$tmp/src" rev-parse --short HEAD)"
TEST_IMPORT_PAUSE=4 rfs-lane seed > "$tmp/seed.out" 2>&1 &
sleep 2
start=$(date +%s)
rfs-lane new c > "$tmp/out" 2>&1
check "mid-refresh lane gets the last good cache" "$one" "$(cat "$HOME/work/rfs-c/game/.godot/stamp" 2>/dev/null)"
check "mid-refresh lane doesn't wait" "1" "$([ $(($(date +%s) - start)) -lt 2 ] && echo 1 || echo 0)"
wait
check "refresh publishes the new cache" "$two" "$(cat "$HOME/work/.rfs-seed-caches/current/.godot/stamp" 2>/dev/null)"
check "old published caches removed" "1" "$(ls "$HOME/work/.rfs-seed-caches" | grep -vc current)"
check "seed import ran through rfs-slot" "1" "$(grep -c $'\tstart\t.*--import' "$tmp/slots/slot.log" | awk '{print ($1 >= 1)}')"

# A seed imported before publishing existed is published by the next refresh, even when current.
rm -rf "$HOME/work/.rfs-seed-caches"
rfs-lane seed --if-stale > "$tmp/out" 2>&1
check "existing seed published" "$two" "$(cat "$HOME/work/.rfs-seed-caches/current/.godot/stamp" 2>/dev/null)"

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
