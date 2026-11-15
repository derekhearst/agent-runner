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
export TMD_DISK_LOW_GB=0 TMD_SWEEP_TMP="$tmp/scratch" TMD_REFLINK=auto PATH="$tmp/bin:$PATH" HOME="$tmp/home" TMD_SLOT_DIR="$tmp/slots" TMD_SLOTS=1 TMD_SLOT_RENDERS=1
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

# sweep: a landed lane goes even with Godot's import churn; work, LANE_KEEP, recent use and a
# process inside keep a lane; a copy of main loses its added files to an archive, not for good.
mkdir -p "$TMD_SWEEP_TMP/claude-1/proj/old-session" "$TMD_SWEEP_TMP/claude-1/proj/new-session"
touch -d '5 days ago' "$TMD_SWEEP_TMP/claude-1/proj/old-session" "$TMD_SWEEP_TMP/old.png"
touch "$TMD_SWEEP_TMP/new.png"
for l in churn edited kept used busy x-before; do rfs-lane new "$l" > "$tmp/out" 2>&1; done
echo churn > "$HOME/work/rfs-churn/game/a.png.import"; echo log > "$HOME/work/rfs-churn/run.log"
echo 3 > "$HOME/work/rfs-edited/game/a.txt"
touch "$HOME/work/rfs-kept/LANE_KEEP"
echo rig > "$HOME/work/rfs-x-before/game/shots.gd"
(cd "$HOME/work/rfs-busy" && exec sleep 30) &
busy=$!
old_files() { find "$HOME/work/rfs-$1" -mindepth 1 -path '*/.git' -prune -o -exec touch -h -d '2 days ago' {} +; }
for l in churn edited kept busy x-before; do old_files "$l"; done
rfs-lane sweep > "$tmp/sweep.out" 2>&1
kill "$busy" 2>/dev/null
gone() { [ -e "$HOME/work/rfs-$1" ] && echo kept || echo removed; }
check "sweep: landed lane with import churn removed" removed "$(gone churn)"
check "sweep: its root log kept" log "$(cat "$HOME/work/runlogs/removed/rfs-churn/run.log" 2>/dev/null)"
check "sweep: uncommitted edit kept" kept "$(gone edited)"
check "sweep: LANE_KEEP kept" kept "$(gone kept)"
check "sweep: lane used within the day kept" kept "$(gone used)"
check "sweep: lane a process sits in kept" kept "$(gone busy)"
check "sweep: copy of main removed" removed "$(gone x-before)"
check "sweep: its added files archived" game/shots.gd "$(tar -tzf "$HOME/work/runlogs/removed/rfs-x-before/added.tgz" 2>/dev/null)"
check "sweep: removal logged" 2 "$(wc -l < "$HOME/work/.rfs-lane-removed.log")"
check "sweep: old scratch cleared" "absent absent" "$([ -e "$TMD_SWEEP_TMP/old.png" ] && echo present || echo absent) $([ -e "$TMD_SWEEP_TMP/claude-1/proj/old-session" ] && echo present || echo absent)"
check "sweep: new scratch kept" "present present" "$([ -e "$TMD_SWEEP_TMP/new.png" ] && echo present || echo absent) $([ -e "$TMD_SWEEP_TMP/claude-1/proj/new-session" ] && echo present || echo absent)"
# An unpushed commit keeps a lane, landed base or not.
cd "$HOME/work/rfs-edited" && git commit -qam wip && old_files edited
rfs-lane sweep > "$tmp/sweep.out" 2>&1
check "sweep: unpushed commit kept" kept "$(gone edited)"
check "sweep: --if-low does nothing with room" "" "$(rfs-lane sweep --if-low 2>&1)"
# A clean lane whose commits are all pushed but not in main goes after a week idle, not before.
for l in concept fresh-concept; do
  rfs-lane new "$l" > "$tmp/out" 2>&1
  (cd "$HOME/work/rfs-$l" && echo c > game/c.txt && git add -A && git commit -qm c && git push -q -u origin HEAD 2>/dev/null)
done
find "$HOME/work/rfs-concept" -mindepth 1 -path '*/.git' -prune -o -exec touch -h -d '8 days ago' {} +
old_files fresh-concept
sed -i -E "s/> [0-9]+ ([-+][0-9]{4})\t/> $(date -d '8 days ago' +%s) \1\t/" "$(git -C "$HOME/work/rfs-concept" rev-parse --absolute-git-dir)/logs/HEAD"
rfs-lane sweep > "$tmp/sweep.out" 2>&1
check "sweep: pushed concept lane idle a week removed" removed "$(gone concept)"
check "sweep: pushed concept lane idle 2 days kept" kept "$(gone fresh-concept)"
check "sweep: its branch stays on origin" 1 "$(git -C "$tmp/origin.git" branch --list claude/rfs-concept | wc -l)"
# rfs-slot under the floor even after a sweep: refused, nothing run, a loud warning.
cd "$HOME/work/rfs-used"
out="$(TMD_DISK_LOW_GB=999999 TMD_DISK_FLOOR_GB=999999 rfs-slot touch "$tmp/ran" 2>&1)"; code=$?
check "rfs-slot: refused under the floor" "75 absent" "$code $([ -e "$tmp/ran" ] && echo present || echo absent)"
check "rfs-slot: low disk warning" 1 "$(grep -c 'LOW DISK' <<<"$out")"

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
