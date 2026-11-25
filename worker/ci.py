#!/usr/bin/env python3
"""rfs-ci: the dev box tests pull requests that cloud tasks push, and reports each result on GitHub.

Cloud tasks (Claude Duet threads, or any session without the game's toolchain) write the code and
push a branch with a pull request. This loop runs inside the dev box container, so its runs share
everything the box's own sessions use: the 48 GB memory cap, the rfs-slot queue (first come first
served, beside Remote Control threads and the issue agent), rfs-lane worktrees seeded from the last
import, and the disk sweep. It never runs anything outside rfs-slot.

Every TMD_CI_POLL seconds (60) it lists the open pull requests of TMD_CI_REPO and, one run at a time:

- Picks the PRs it may run: the branch is in the repository itself (never a fork), and the PR's
  author is in TMD_CI_AUTHORS (derekhearst) or someone with triage access added the label
  `box: test`. `box: skip` turns it off for a PR. A branch that a box lane has checked out is left
  to that lane's session, which runs its own tests.
- Reads the head commit's `Box-Test:` trailer. `Box-Test: lobby` (a suite folder, a test name,
  `tools`, `assets` or `landing`) runs that suite as the `box/test` check; `Box-Test: none` runs
  nothing; no trailer runs the landing suite (`tools/test.sh landing`) as the `box/landing` check.
  Only the newest push of a PR is tested: an older head still queued is marked superseded.
- Tests in the lane ~/work/rfs-ci-pr-N (rfs-lane new ... --branch HEAD_BRANCH, then a hard reset to
  each new head), through `rfs-slot tools/test.sh SUITE`, with no GitHub token in the run's
  environment. Logs: ~/work/runlogs/ci/.
- Reports a commit status (pending while queued and running, then success, failure or error) and
  keeps one comment on the PR up to date with the result and, on a failure, the end of the log.
- Removes the lane of a PR that has closed (rfs-lane done --force, which still keeps uncommitted
  or unpushed work).

Usage: rfs-ci [--once] [--dry-run]. --dry-run lists what it would run and posts nothing.
Needs GH_TOKEN (a fine-grained PAT with Commit statuses RW and Pull requests RW on the repo).
"""
import json
import os
import re
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field

REPO = os.environ.get("TMD_CI_REPO", "derekhearst/TheMerrowDeep")
AUTHORS = {a.strip().lower() for a in os.environ.get("TMD_CI_AUTHORS", "derekhearst").split(",") if a.strip()}
RUN_LABEL = os.environ.get("TMD_CI_LABEL", "box: test")
SKIP_LABEL = os.environ.get("TMD_CI_SKIP_LABEL", "box: skip")
POLL_SECONDS = int(os.environ.get("TMD_CI_POLL", "60"))
TIMEOUT_MINUTES = int(os.environ.get("TMD_CI_TIMEOUT", "240"))
HOME = os.environ.get("HOME", "/home/agent")
MAIN = os.environ.get("TMD_MAIN_CHECKOUT", os.environ.get("RFS_MAIN", f"{HOME}/work/RigForSilent"))
ROOT = os.path.dirname(MAIN)
LOGS = os.environ.get("TMD_CI_LOGS", f"{ROOT}/runlogs/ci")
LANDING = "landing"
MARKER = "<!-- box-ci -->"
TAIL_LINES = 60
# rfs-slot refuses these outside landing (13 Nov); a trailer naming one is answered, not queued.
WHOLE_SUITES = {"all", "quick", "slow"}
SUITE_NAME = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_:./-]{0,80}$")
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
TRAILER = re.compile(r"^box-test:[ \t]*(\S*)[ \t]*$", re.IGNORECASE | re.MULTILINE)
# What the run's environment never gets: the token reaches only this loop's own gh and git calls.
SECRET_ENV = ("GH_TOKEN", "GITHUB_TOKEN", "CI_GH_TOKEN", "GH_CONFIG_DIR")


@dataclass
class Job:
	number: int
	sha: str
	branch: str
	context: str  # box/test or box/landing
	suite: str
	problem: str = ""  # set when the trailer can't be run: reported as an error, nothing runs


@dataclass
class PrState:
	sha: str = ""
	jobs: list = field(default_factory=list)
	results: dict = field(default_factory=dict)  # context -> (state, summary, tail)
	comment_id: int | None = None


prs: dict[int, PrState] = {}
dry_run = "--dry-run" in sys.argv


def log(message: str) -> None:
	print(time.strftime("%F %T"), message, flush=True)


def gh(*args: str) -> str:
	result = subprocess.run(["gh", *args], capture_output=True, text=True)
	if result.returncode != 0:
		raise RuntimeError(f"gh {' '.join(args[:3])} failed: {result.stderr.strip()[:300]}")
	return result.stdout


def git(*args: str, cwd: str = MAIN) -> str:
	result = subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True,
		env={**os.environ, "GIT_LFS_SKIP_SMUDGE": "1"})
	if result.returncode != 0:
		raise RuntimeError(f"git {' '.join(args[:2])} failed: {result.stderr.strip()[:300]}")
	return result.stdout


# --- pure rules (tested in test_ci.py) ---------------------------------------------------------


def trailer_suite(message: str) -> str | None:
	"""The suite a commit's `Box-Test:` trailer names ("" for an empty one), or None without one."""
	paragraphs = [p for p in message.strip().split("\n\n") if p.strip()]
	if len(paragraphs) < 2:
		return None  # a trailer lives in the last paragraph, after the subject
	found = TRAILER.findall(paragraphs[-1])
	return found[-1] if found else None


def jobs_for(number: int, sha: str, branch: str, message: str) -> list[Job]:
	"""What to run for a PR head: one job, or none for `Box-Test: none`."""
	suite = trailer_suite(message)
	if suite is None:
		return [Job(number, sha, branch, "box/landing", LANDING)]
	if suite.lower() == "none":
		return []
	job = Job(number, sha, branch, "box/test", suite)
	if not SUITE_NAME.match(suite):
		job.problem = "Box-Test names no suite the box can run"
	elif suite in WHOLE_SUITES:
		job.problem = f"the box runs {suite} only inside landing: use Box-Test: landing or a suite folder"
	return [job]


def eligible(pr: dict) -> str:
	"""Why a PR isn't run here ("" when it is)."""
	labels = {label["name"] for label in pr.get("labels", [])}
	head_repo = (pr.get("head", {}).get("repo") or {}).get("full_name", "")
	if head_repo.lower() != REPO.lower():
		return "from a fork"
	if SKIP_LABEL in labels:
		return f"labelled {SKIP_LABEL}"
	if pr["user"]["login"].lower() not in AUTHORS and RUN_LABEL not in labels:
		return f"author not in TMD_CI_AUTHORS and no {RUN_LABEL} label"
	return ""


def outcome(code: int | None) -> str:
	"""The commit status for a run's exit code (None: it timed out)."""
	if code == 0:
		return "success"
	if code is None or code == 75:
		return "error"  # timed out, or rfs-slot refused (low disk) or gave up: nothing judged the code
	return "failure"


def summary_line(text: str) -> str:
	"""The run's own one-line verdict: tmd's summary if it printed one, else its last line."""
	lines = [ANSI.sub("", line).strip() for line in text.splitlines()]
	lines = [line for line in lines if line]
	for line in reversed(lines):
		if line.startswith(("tmd test", "tmd: ", "rfs-slot")):
			return line
	return lines[-1] if lines else "no output"


def describe(text: str, limit: int = 140) -> str:
	return text if len(text) <= limit else text[: limit - 1] + "…"


def tail(text: str, n: int = TAIL_LINES) -> str:
	lines = [ANSI.sub("", line)[:300] for line in text.splitlines()]
	return "\n".join(lines[-n:]).replace("```", "'''")


def render_comment(sha: str, results: dict) -> str:
	icons = {"success": "passed", "failure": "FAILED", "error": "could not run", "pending": "running"}
	out = [MARKER, f"**TrueNAS box tests** for `{sha[:9]}`", ""]
	for context, (state, summary, log_tail) in sorted(results.items()):
		out.append(f"- `{context}`: {icons.get(state, state)}. {summary}")
		if state in ("failure", "error") and log_tail:
			out += ["", "<details><summary>End of the log</summary>", "", "```text", log_tail, "```", "</details>", ""]
	out += ["", "Rerun a suite: push a commit with a `Box-Test: SUITE` trailer (`Box-Test: none` skips the box)."]
	return "\n".join(out)


# --- GitHub ------------------------------------------------------------------------------------


def set_status(sha: str, context: str, state: str, description: str) -> None:
	if dry_run:
		log(f"[dry run] {sha[:9]} {context}: {state} {description}")
		return
	gh("api", f"repos/{REPO}/statuses/{sha}", "-f", f"state={state}", "-f", f"context={context}",
		"-f", f"description={describe(description)}")


def reported(sha: str) -> dict:
	"""context -> state of this repo's box statuses on a commit, newest first wins."""
	out = json.loads(gh("api", f"repos/{REPO}/commits/{sha}/statuses?per_page=100"))
	states: dict = {}
	for status in out:
		if status["context"].startswith("box/"):
			states.setdefault(status["context"], status["state"])
	return states


def upsert_comment(number: int, state: PrState) -> None:
	body = render_comment(state.sha, state.results)
	if dry_run:
		return
	if state.comment_id is None:
		comments = json.loads(gh("api", f"repos/{REPO}/issues/{number}/comments?per_page=100"))
		state.comment_id = next((c["id"] for c in comments if MARKER in (c.get("body") or "")), None)
	if state.comment_id is None:
		created = json.loads(gh("api", f"repos/{REPO}/issues/{number}/comments", "-f", f"body={body}"))
		state.comment_id = created["id"]
	else:
		gh("api", "-X", "PATCH", f"repos/{REPO}/issues/comments/{state.comment_id}", "-f", f"body={body}")


# --- the box -----------------------------------------------------------------------------------


def lane_dir(number: int) -> str:
	return f"{ROOT}/rfs-ci-pr-{number}"


def branches_in_use() -> dict[str, str]:
	"""branch -> worktree path for every worktree of the main checkout."""
	found, path = {}, ""
	for line in git("worktree", "list", "--porcelain").splitlines():
		if line.startswith("worktree "):
			path = line[9:]
		elif line.startswith("branch refs/heads/"):
			found[line[18:]] = path
	return found


def prepare_lane(job: Job) -> str:
	"""The lane at the job's head, or "" when the branch has moved on (a newer push supersedes it)."""
	lane = lane_dir(job.number)
	if not os.path.isdir(lane):
		subprocess.run(["rfs-lane", "new", f"ci-pr-{job.number}", "--branch", job.branch], check=True,
			env={**os.environ, "TMD_MAIN_CHECKOUT": MAIN})
	git("fetch", "-q", "origin", job.branch, cwd=lane)
	if git("rev-parse", f"origin/{job.branch}", cwd=lane).strip() != job.sha:
		return ""
	git("reset", "-q", "--hard", job.sha, cwd=lane)
	git("clean", "-q", "-fd", cwd=lane)  # untracked only; the ignored import cache stays
	subprocess.run(["git", "-C", lane, "lfs", "pull"], check=True)
	# Reflinks of the objects, as rfs-lane makes them, so a lane costs a few GB rather than ~20.
	subprocess.run(["git", "-C", lane, "lfs", "dedup"], capture_output=True)
	return lane


def run_suite(lane: str, job: Job) -> tuple[int | None, str]:
	os.makedirs(LOGS, exist_ok=True)
	path = f"{LOGS}/pr-{job.number}-{job.sha[:9]}-{job.suite.replace('/', '_')}.log"
	env = {k: v for k, v in os.environ.items() if k not in SECRET_ENV}
	# Waits its turn however long the queue is: CI has nobody to hand an exit 75 back to.
	env.update(TMD_SLOT_MAX_WAIT="0", DISPLAY=env.get("DISPLAY", ":99"))
	with open(path, "w") as out:
		proc = subprocess.Popen(["rfs-slot", "tools/test.sh", job.suite], cwd=lane, env=env,
			stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
		try:
			code = proc.wait(timeout=TIMEOUT_MINUTES * 60)
		except subprocess.TimeoutExpired:
			os.killpg(proc.pid, signal.SIGTERM)
			try:
				proc.wait(timeout=60)
			except subprocess.TimeoutExpired:
				os.killpg(proc.pid, signal.SIGKILL)
			code = None
	with open(path, errors="replace") as f:
		text = f.read()
	log(f"PR #{job.number} {job.context} {job.suite}: exit {code}, log {path}")
	return code, text


def run(job: Job) -> None:
	state = prs[job.number]
	if job.problem:
		set_status(job.sha, job.context, "error", job.problem)
		state.results[job.context] = ("error", job.problem, "")
		upsert_comment(job.number, state)
		return
	set_status(job.sha, job.context, "pending", f"tools/test.sh {job.suite}: waiting for a box slot")
	try:
		lane = prepare_lane(job)
	except (RuntimeError, subprocess.CalledProcessError) as error:
		set_status(job.sha, job.context, "error", f"couldn't check out the branch on the box: {error}")
		log(f"PR #{job.number}: lane failed: {error}")
		return
	if not lane:
		set_status(job.sha, job.context, "error", "superseded by a newer push before its turn")
		return
	code, text = run_suite(lane, job)
	verdict = outcome(code)
	summary = f"timed out after {TIMEOUT_MINUTES} min" if code is None else summary_line(text)
	set_status(job.sha, job.context, verdict, summary)
	if state.sha == job.sha:
		state.results[job.context] = (verdict, summary, tail(text) if verdict != "success" else "")
		upsert_comment(job.number, state)


def plan() -> list[Job]:
	"""Refreshes what each open PR needs and returns the jobs to run, oldest head first."""
	open_prs = json.loads(gh("api", f"repos/{REPO}/pulls?state=open&per_page=100"))
	in_use = branches_in_use()
	seen = set()
	for pr in open_prs:
		number, sha, branch = pr["number"], pr["head"]["sha"], pr["head"]["ref"]
		seen.add(number)
		why = eligible(pr)
		owner = in_use.get(branch)
		if not why and owner and owner != lane_dir(number):
			why = f"checked out in the box lane {owner}, which runs its own tests"
		state = prs.setdefault(number, PrState())
		if why:
			if state.sha != sha:
				log(f"PR #{number} skipped: {why}")
			state.sha, state.jobs = sha, []
			continue
		if state.sha == sha:
			continue
		for old in state.jobs:  # an older head still waiting: the new push replaces it
			set_status(old.sha, old.context, "error", "superseded by a newer push before its turn")
		message = json.loads(gh("api", f"repos/{REPO}/commits/{sha}"))["commit"]["message"]
		done = reported(sha)
		state.sha, state.results = sha, {}
		state.jobs = [j for j in jobs_for(number, sha, branch, message) if done.get(j.context) in (None, "pending")]
		for job in state.jobs:
			set_status(sha, job.context, "pending", f"tools/test.sh {job.suite}: queued on the TrueNAS box")
		if state.jobs:
			log(f"PR #{number} {sha[:9]} queued: {', '.join(j.suite for j in state.jobs)}")
	for number in [n for n in prs if n not in seen]:
		del prs[number]
		close_lane(number)
	return [job for state in prs.values() for job in state.jobs]


def close_lane(number: int) -> None:
	if dry_run or not os.path.isdir(lane_dir(number)):
		return
	result = subprocess.run(["rfs-lane", "done", f"ci-pr-{number}", "--force"], capture_output=True, text=True)
	log(f"PR #{number} closed: {(result.stdout + result.stderr).strip()[:200]}")


def main() -> None:
	log(f"rfs-ci watching {REPO} (authors {', '.join(sorted(AUTHORS))}){' [dry run]' if dry_run else ''}")
	if not os.path.exists(f"{MAIN}/.git"):
		log(f"no main checkout at {MAIN}; waiting for one")
	while True:
		try:
			jobs = plan() if os.path.exists(f"{MAIN}/.git") else []
			if jobs and not dry_run:
				job = jobs[0]
				prs[job.number].jobs.remove(job)
				run(job)
				continue  # look again at once: a push may have landed during the run
		except Exception as error:  # noqa: BLE001 - one bad cycle must not stop CI
			log(f"cycle failed: {error}")
		if "--once" in sys.argv or dry_run:
			return
		time.sleep(POLL_SECONDS)


if __name__ == "__main__":
	main()
