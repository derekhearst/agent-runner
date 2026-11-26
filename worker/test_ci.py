"""Tests for rfs-ci (ci.py): what it runs for a PR, and how it reports. Run: python3 test_ci.py"""
import json
import os
import stat
import tempfile
import time

os.environ["TMD_CI_REPO"] = "derekhearst/TheMerrowDeep"
os.environ["TMD_CI_AUTHORS"] = "derekhearst"
os.environ["TMD_CI_TIMEOUT"] = "1"

import ci  # noqa: E402


def check(name: str, got, want) -> None:
	assert got == want, f"{name}: got {got!r}, want {want!r}"
	print("ok  ", name)


# --- the Box-Test trailer picks the suite ---
check("no trailer", ci.trailer_suite("Fix the helm\n\nLonger body."), None)
check("subject only is no trailer", ci.trailer_suite("Box-Test: lobby"), None)
check("trailer", ci.trailer_suite("Fix the helm\n\nBody.\n\nBox-Test: lobby"), "lobby")
check("trailer among others", ci.trailer_suite("Fix\n\nCo-Authored-By: A <a@b>\nbox-test: sim"), "sim")
check("last trailer wins", ci.trailer_suite("Fix\n\nBox-Test: sim\nBox-Test: tools"), "tools")
check("only the last paragraph", ci.trailer_suite("Fix\n\nBox-Test: sim\n\nSigned-off-by: A"), None)

sha, branch = "a" * 40, "claude/helm"
check("no trailer -> landing", [(j.context, j.suite) for j in ci.jobs_for(7, sha, branch, "Fix")],
	[("box/landing", "landing")])
check("trailer -> box/test", [(j.context, j.suite) for j in ci.jobs_for(7, sha, branch, "Fix\n\nBox-Test: lobby")],
	[("box/test", "lobby")])
check("Box-Test: none runs nothing", ci.jobs_for(7, sha, branch, "Fix\n\nBox-Test: none"), [])
check("whole suite answered, not queued",
	bool(ci.jobs_for(7, sha, branch, "Fix\n\nBox-Test: all")[0].problem), True)
check("odd name answered", bool(ci.jobs_for(7, sha, branch, "Fix\n\nBox-Test: $(rm)")[0].problem), True)
check("test name allowed", ci.jobs_for(7, sha, branch, "Fix\n\nBox-Test: shot_args::test_pick")[0].problem, "")

# --- Box-Shot: pictures from the PR's own manifest ---
check("shots trailer", [(j.context, j.suite) for j in ci.jobs_for(7, sha, branch, "Fix\n\nBox-Test: none\nBox-Shot: plumbing")],
	[("box/shots", "plumbing")])
check("shots after the landing suite", [j.context for j in ci.jobs_for(7, sha, branch, "Fix\n\nBox-Shot: plumbing")],
	["box/landing", "box/shots"])
check("Box-Shot: none", [j.context for j in ci.jobs_for(7, sha, branch, "Fix\n\nBox-Test: none\nBox-Shot: none")], [])
check("bad shots name answered", bool(ci.jobs_for(7, sha, branch, "Fix\n\nBox-Test: none\nBox-Shot: ../x")[0].problem), True)
steps, problem = ci.parse_manifest("# before and after\n\ntools/bpy.sh art-src/x.py --only a\n"
	"tools/shot.sh res://a.tscn out/ci_shots/after --only='tube wall'\ntools/godot.sh --import\n")
check("manifest steps", (steps, problem), ([["tools/bpy.sh", "art-src/x.py", "--only", "a"],
	["tools/shot.sh", "res://a.tscn", "out/ci_shots/after", "--only=tube wall"], ["tools/godot.sh", "--import"]], ""))
check("manifest refuses other commands", bool(ci.parse_manifest("rm -rf /")[1]), True)
check("manifest refuses tests", bool(ci.parse_manifest("tools/test.sh all")[1]), True)
check("manifest refuses a game run", bool(ci.parse_manifest("tools/godot.sh")[1]), True)
check("manifest refuses chains", bool(ci.parse_manifest("tools/bpy.sh a.py && tools/shot.sh b c")[1]), True)
check("empty manifest", bool(ci.parse_manifest("# nothing\n")[1]), True)
check("picture names", ci.picture_name("after/tube wall.png"), "after__tube_wall.jpg")
body = ci.render_comment(sha, {"box/shots": ("success", "2 pictures", "")}, [("a.jpg", "https://x/a.jpg?raw=true")])
check("comment shows the pictures", '<img src="https://x/a.jpg?raw=true"' in body, True)

# --- which PRs run ---
def pr(login="derekhearst", head="derekhearst/TheMerrowDeep", labels=()):
	return {"user": {"login": login}, "head": {"repo": {"full_name": head}}, "labels": [{"name": n} for n in labels]}


check("owner's PR runs", ci.eligible(pr()), "")
check("fork never runs", ci.eligible(pr(head="someone/TheMerrowDeep", labels=["box: test"])), "from a fork")
check("deleted fork never runs", ci.eligible({**pr(), "head": {"repo": None}}), "from a fork")
check("contributor without label", bool(ci.eligible(pr(login="Jalonki"))), True)
check("contributor with label", ci.eligible(pr(login="Jalonki", labels=["box: test"])), "")
check("skip label", ci.eligible(pr(labels=["box: skip"])), "labelled box: skip")

# --- verdicts ---
check("pass", ci.outcome(0), "success")
check("tests failed", ci.outcome(1), "failure")
check("rfs-slot refused", ci.outcome(75), "error")
check("timed out", ci.outcome(None), "error")
check("tmd summary", ci.summary_line("x\n\x1b[31mtmd test landing: all ok, assets FAIL\x1b[0m\ntrailing"),
	"tmd test landing: all ok, assets FAIL")
check("last line otherwise", ci.summary_line("one\ntwo\n\n"), "two")
check("description cap", len(ci.describe("x" * 300)), 140)
check("comment keeps fences closed", "```" in ci.tail("a\n```\nb"), False)
body = ci.render_comment(sha, {"box/landing": ("failure", "tmd test landing: all FAIL", "boom")})
check("comment has marker", body.startswith(ci.MARKER), True)
check("comment has the log tail", "boom" in body, True)

# --- plan(): statuses, superseded heads, lanes of closed PRs ---
calls: list = []
pulls = [{"number": 7, "head": {"sha": sha, "ref": branch, "repo": {"full_name": "derekhearst/TheMerrowDeep"}},
	"user": {"login": "derekhearst"}, "labels": []},
	{"number": 8, "head": {"sha": "b" * 40, "ref": "claude/rfs-lights", "repo": {"full_name": "derekhearst/TheMerrowDeep"}},
	"user": {"login": "derekhearst"}, "labels": []}]
statuses: dict = {}


def fake_gh(*args):
	calls.append(args)
	path = next((a for a in args if a.startswith("repos/")), "")
	if path.startswith("repos/derekhearst/TheMerrowDeep/pulls"):
		return json.dumps(pulls)
	if "/commits/" in path and path.endswith("/statuses?per_page=100"):
		return json.dumps(statuses.get(path.split("/")[4], []))
	if "/commits/" in path:
		return json.dumps({"commit": {"message": "Fix the helm"}})
	return "{}"


ci.gh = fake_gh
ci.branches_in_use = lambda: {"main": ci.MAIN, "claude/rfs-lights": ci.ROOT + "/rfs-lights"}
jobs = ci.plan()
check("box lane's branch left to it, cloud PR queued", [(j.number, j.suite) for j in jobs], [(7, "landing")])
check("queued status posted", any("statuses/" + sha in a[1] for a in calls if len(a) > 1), True)

calls.clear()
check("same head: still the one job", [(j.number, j.suite) for j in ci.plan()], [(7, "landing")])
check("same head: no extra API calls", len(calls), 1)

pulls[0]["head"]["sha"] = "c" * 40
calls.clear()
ci.plan()
superseded = [a for a in calls if len(a) > 1 and a[1].endswith("statuses/" + sha)]
check("older queued head marked superseded", bool(superseded) and "state=error" in superseded[0], True)

statuses["d" * 40] = [{"context": "box/landing", "state": "success"}]
pulls[0]["head"]["sha"] = "d" * 40
check("already reported head isn't rerun", [j for j in ci.plan() if j.number == 7], [])

closed: list = []
ci.close_lane = closed.append
pulls.pop(0)
ci.plan()
check("closed PR's lane removed", closed, [7])

# --- run_suite(): through rfs-slot, without the token, with a timeout ---
with tempfile.TemporaryDirectory() as tmp:
	bin_dir = os.path.join(tmp, "bin")
	os.makedirs(bin_dir)
	slot = os.path.join(bin_dir, "rfs-slot")
	with open(slot, "w") as f:
		f.write('#!/bin/bash\necho "args: $*"\necho "token: ${GH_TOKEN:-none} wait: $TMD_SLOT_MAX_WAIT"\n'
			'[ "$2" = slow ] && sleep 120\necho "tmd test $2: all ok"\n')
	os.chmod(slot, stat.S_IRWXU)
	os.environ["PATH"] = bin_dir + os.pathsep + os.environ["PATH"]
	os.environ["GH_TOKEN"] = "secret"
	ci.LOGS = os.path.join(tmp, "logs")
	code, text = ci.run_suite(tmp, ci.Job(7, sha, branch, "box/test", "lobby"))
	check("ran through rfs-slot", "args: tools/test.sh lobby" in text, True)
	check("no token in the run", "token: none" in text, True)
	check("waits its turn", "wait: 0" in text, True)
	check("exit code", code, 0)
	ci.TIMEOUT_MINUTES = 0.02  # 1.2 s
	code, text = ci.run_suite(tmp, ci.Job(7, sha, branch, "box/test", "slow"))
	check("timeout kills the run", code, None)

# --- run_shots() and publish_shots(): each step through rfs-slot, pictures to the shots branch ---
import subprocess  # noqa: E402

with tempfile.TemporaryDirectory() as tmp:
	ci.TIMEOUT_MINUTES = 1
	ci.ROOT = tmp
	ci.LOGS = os.path.join(tmp, "logs")
	bin_dir = os.path.join(tmp, "bin")
	os.makedirs(bin_dir)
	slot = os.path.join(bin_dir, "rfs-slot")
	with open(slot, "w") as f:  # a shot step writes a picture where it was told to
		f.write('#!/bin/bash\necho "step: $* token: ${GH_TOKEN:-none}"\n[ "$1" = tools/bpy.sh ] && [ "$2" = fail ] && exit 3\n'
			'if [ "$1" = tools/shot.sh ]; then mkdir -p "$3"; cp "$PICTURE" "$3/view one.png"; fi\nexit 0\n')
	os.chmod(slot, stat.S_IRWXU)
	os.environ["PATH"] = bin_dir + os.pathsep + os.environ["PATH"]
	os.environ["PICTURE"] = os.path.join(tmp, "real.png")
	try:
		from PIL import Image
		Image.new("RGB", (2560, 1440), (200, 180, 150)).save(os.environ["PICTURE"])
	except ImportError:  # the box may have no Pillow: then the file is published as it is
		open(os.environ["PICTURE"], "wb").write(b"\x89PNG\r\n\x1a\n")
	lane = os.path.join(tmp, "lane")
	os.makedirs(os.path.join(lane, "tools", "ci_shots"))
	os.makedirs(os.path.join(lane, "out", "ci_shots", "stale"))
	open(os.path.join(lane, "out", "ci_shots", "stale", "old.png"), "w").close()
	with open(os.path.join(lane, "tools", "ci_shots", "plumbing.txt"), "w") as f:
		f.write("tools/bpy.sh art-src/x.py\ntools/shot.sh res://a.tscn out/ci_shots/after --only=x\n")
	with open(os.path.join(lane, "tools", "ci_shots", "broken.txt"), "w") as f:
		f.write("tools/bpy.sh fail\ntools/shot.sh res://a.tscn out/ci_shots/after\n")
	job = ci.Job(7, sha, branch, "box/shots", "plumbing")
	code, text, pictures, problem = ci.run_shots(lane, job)
	check("shots ran each step through rfs-slot", (code, text.count("step: "), problem), (0, 2, ""))
	check("no token in a shots run", "token: none" in text and "secret" not in text, True)
	check("only this run's pictures", pictures, ["after/view one.png"])
	code, text, pictures, problem = ci.run_shots(lane, ci.Job(7, sha, branch, "box/shots", "broken"))
	check("a failing step stops the run", (code, text.count("step: "), pictures), (3, 1, []))
	check("missing manifest", bool(ci.run_shots(lane, ci.Job(7, sha, branch, "box/shots", "nope"))[3]), True)

	# The shots branch: a local bare repo stands in for GitHub.
	origin = os.path.join(tmp, "origin.git")
	env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
		"GIT_COMMITTER_EMAIL": "t@t"}
	subprocess.run(["git", "init", "-q", "--bare", origin], check=True)
	seed = os.path.join(tmp, "seed")
	subprocess.run(["git", "init", "-q", "-b", "pr-shots", seed], check=True)
	open(os.path.join(seed, "README.md"), "w").write("shots\n")
	subprocess.run(["git", "-C", seed, "add", "."], check=True)
	subprocess.run(["git", "-C", seed, "commit", "-q", "-m", "seed"], check=True, env=env)
	subprocess.run(["git", "-C", seed, "push", "-q", origin, "pr-shots"], check=True)
	ci.SHOTS_REMOTE = origin
	ci.run_shots(lane, job)
	published, note = ci.publish_shots(lane, job, ["after/view one.png"])
	check("published url", published, [("after__view_one.jpg", ci.shots_url(7, sha, "after__view_one.jpg"))])
	listed = subprocess.run(["git", "-C", origin, "ls-tree", "-r", "--name-only", "pr-shots"], capture_output=True,
		text=True).stdout.split()
	check("pushed to the shots branch", listed, ["README.md", f"ci/pr-7/{sha[:9]}/after__view_one.jpg"])
	published, note = ci.publish_shots(lane, job, ["after/view one.png"])
	check("a second publish reuses the clone", len(published), 1)
	try:
		from PIL import Image
		with Image.open(os.path.join(tmp, "rfs-ci-shots", f"ci/pr-7/{sha[:9]}", "after__view_one.jpg")) as shot:
			check("scaled to review size", (shot.format, shot.width), ("JPEG", ci.SHOT_WIDTH))
	except ImportError:
		pass

# --- clear_stale_locks(): a killed run's git locks don't block the next checkout ---
with tempfile.TemporaryDirectory() as tmp:
	repo = os.path.join(tmp, "lane")
	subprocess.run(["git", "init", "-q", repo], check=True)
	gitdir = os.path.join(repo, ".git")
	old_lock, new_lock = os.path.join(gitdir, "index.lock"), os.path.join(gitdir, "HEAD.lock")
	open(old_lock, "w").close()
	open(new_lock, "w").close()
	past = time.time() - ci.STALE_LOCK_S - 60
	os.utime(old_lock, (past, past))
	check("an old lock goes", ci.clear_stale_locks(repo), [old_lock])
	check("a fresh lock stays", os.path.exists(new_lock), True)
	check("not a repo: nothing", ci.clear_stale_locks(os.path.join(tmp, "nope")), [])

print("all ok")
