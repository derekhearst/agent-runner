#!/bin/bash
# End-to-end test of rfs-ci's lane handling with the real rfs-lane and rfs-slot: a PR branch gets
# its own lane, a new push resets it, a push it hasn't fetched yet supersedes the job, the suite
# runs through rfs-slot's queue, and a closed PR's lane is removed.
# Run: bash worker/test_ci_lane.sh (needs git and git-lfs; no Godot or GitHub).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
ln -s "$here/rfs-slot.sh" "$tmp/bin/rfs-slot"
ln -s "$here/rfs-lane.sh" "$tmp/bin/rfs-lane"
export TMD_DISK_LOW_GB=0 TMD_SWEEP_TMP="$tmp/scratch" TMD_REFLINK=auto PATH="$tmp/bin:$PATH" HOME="$tmp/home" \
  TMD_SLOT_DIR="$tmp/slots" TMD_SLOTS=1 TMD_SLOT_RENDERS=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME/work"
git config --global init.defaultBranch main
git config --global advice.detachedHead false

# origin: a fake tools/test.sh that reports which commit it tested and fails when told to.
git init -q "$tmp/src" && cd "$tmp/src"
mkdir -p tools game
cat > tools/test.sh <<'EOF'
#!/bin/bash
cat game/fail 2>/dev/null && exit 1
echo "tmd test $1: all ok at $(git rev-parse --short HEAD)"
EOF
chmod +x tools/test.sh
echo .godot > game/.gitignore
git add -A && git commit -qm one
git checkout -qb claude/helm && echo 1 > game/helm.txt && git add -A && git commit -qm helm && git checkout -q main
git clone -q --bare "$tmp/src" "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$HOME/work/RigForSilent"

TMD_MAIN_CHECKOUT="$HOME/work/RigForSilent" python3 - "$here" "$tmp" <<'PY'
import os, subprocess, sys
sys.path.insert(0, sys.argv[1])
tmp = sys.argv[2]
os.environ["TMD_CI_LOGS"] = f"{tmp}/logs"
import ci

def check(name, got, want):
	assert got == want, f"{name}: got {got!r}, want {want!r}"
	print("ok  ", name)

def head(ref):
	return subprocess.run(["git", "-C", f"{tmp}/origin.git", "rev-parse", ref], capture_output=True, text=True).stdout.strip()

def push(change, fail=False):
	subprocess.run(f"cd {tmp}/src && git checkout -q claude/helm && echo {change} > game/helm.txt"
		+ (" && echo boom > game/fail" if fail else " && rm -f game/fail")
		+ f" && git add -A && git commit -qm {change} && git push -q {tmp}/origin.git claude/helm", shell=True, check=True)

job = ci.Job(12, head("claude/helm"), "claude/helm", "box/landing", "landing")
lane = ci.prepare_lane(job)
check("lane made for the PR", lane, f"{ci.ROOT}/rfs-ci-pr-12")
code, text = ci.run_suite(lane, job)
check("suite passed through rfs-slot", (code, f"at {job.sha[:7]}" in text), (0, True))
check("rfs-slot logged the run", "tools/test.sh" in open(f"{os.environ['TMD_SLOT_DIR']}/slot.log").read(), True)

push("two", fail=True)
job = ci.Job(12, head("claude/helm"), "claude/helm", "box/landing", "landing")
lane = ci.prepare_lane(job)
code, text = ci.run_suite(lane, job)
check("new push: same lane reset to it, failure seen", (lane.endswith("rfs-ci-pr-12"), ci.outcome(code), "boom" in text),
	(True, "failure", True))

stale = job
push("three")
check("a newer push supersedes a queued head", ci.prepare_lane(stale), "")
check("branch in use maps to the CI lane", ci.branches_in_use().get("claude/helm"), lane)

result = subprocess.run(["rfs-lane", "done", "ci-pr-12", "--force"], capture_output=True, text=True)
check("closed PR's lane removed", (result.returncode, os.path.exists(lane)), (0, False))
print("all ok")
PY
