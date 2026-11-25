"""Tests for rfs-ci (ci.py): what it runs for a PR, and how it reports. Run: python3 test_ci.py"""
import json
import os
import stat
import tempfile

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

print("all ok")
