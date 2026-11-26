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
- Renders pictures when the head commit also has a `Box-Shot: NAME` trailer (the `box/shots`
  check): runs the steps listed in the PR's own tools/ci_shots/NAME.txt, one line per step, each
  through rfs-slot (tools/shot.sh, tools/bpy.sh or tools/godot.sh --import only), then publishes
  every picture the steps wrote under out/ci_shots/ to the repo's orphan branch `pr-shots`
  (ci/pr-N/SHA/, as review-size JPGs) and shows them in the PR comment. Needs Contents RW on the
  repo for that push.
- Removes the lane of a PR that has closed (rfs-lane done --force, which still keeps uncommitted
  or unpushed work).

Usage: rfs-ci [--once] [--dry-run]. --dry-run lists what it would run and posts nothing.
Needs GH_TOKEN (a fine-grained PAT with Commit statuses RW and Pull requests RW on the repo).
"""
import json
import os
import re
import shlex
import shutil
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
SHOT_TRAILER = re.compile(r"^box-shot:[ \t]*(\S*)[ \t]*$", re.IGNORECASE | re.MULTILINE)
SHOT_NAME = re.compile(r"^[a-z0-9][a-z0-9_-]{0,40}$")
SHOTS_DIR = "out/ci_shots"  # where a shots manifest's steps write their pictures, in the lane
SHOT_STEPS = {"tools/shot.sh", "tools/bpy.sh", "tools/godot.sh"}
SHOT_MAX_STEPS = 12
SHOT_MAX_FILES = 24
SHOT_WIDTH = 1280  # review size: published pictures are scaled to this width
SHOT_MAX_BYTES = 3 * 1024 * 1024  # a picture that can't be scaled (no Pillow) is skipped past this
PICTURE = re.compile(r"\.(png|jpe?g)$", re.IGNORECASE)
SHOTS_BRANCH = os.environ.get("TMD_CI_SHOTS_BRANCH", "pr-shots")
SHOTS_REMOTE = os.environ.get("TMD_CI_SHOTS_REMOTE", f"https://github.com/{REPO}.git")
# What the run's environment never gets: the token reaches only this loop's own gh and git calls.
SECRET_ENV = ("GH_TOKEN", "GITHUB_TOKEN", "CI_GH_TOKEN", "GH_CONFIG_DIR")


@dataclass
class Job:
	number: int
	sha: str
	branch: str
	context: str  # box/test, box/landing or box/shots
	suite: str  # a test suite, or for box/shots the manifest's name
	problem: str = ""  # set when the trailer can't be run: reported as an error, nothing runs


@dataclass
class PrState:
	sha: str = ""
	jobs: list = field(default_factory=list)
	results: dict = field(default_factory=dict)  # context -> (state, summary, tail)
	comment_id: int | None = None
	pictures: list = field(default_factory=list)  # (name, url) published by this head's box/shots


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


def trailer_value(message: str, pattern: re.Pattern = TRAILER) -> str | None:
	"""The value a commit's trailer gives ("" for an empty one), or None without one."""
	paragraphs = [p for p in message.strip().split("\n\n") if p.strip()]
	if len(paragraphs) < 2:
		return None  # a trailer lives in the last paragraph, after the subject
	found = pattern.findall(paragraphs[-1])
	return found[-1] if found else None


def trailer_suite(message: str) -> str | None:
	"""The suite a commit's `Box-Test:` trailer names ("" for an empty one), or None without one."""
	return trailer_value(message, TRAILER)


def shots_job(number: int, sha: str, branch: str, message: str) -> list[Job]:
	"""The box/shots job a `Box-Shot: NAME` trailer asks for, or none."""
	name = trailer_value(message, SHOT_TRAILER)
	if name is None or name.lower() == "none":
		return []
	job = Job(number, sha, branch, "box/shots", name)
	if not SHOT_NAME.match(name):
		job.problem = "Box-Shot names no manifest: use lower-case letters, digits, - and _ (tools/ci_shots/NAME.txt)"
	return [job]


def parse_manifest(text: str) -> tuple[list[list[str]], str]:
	"""A shots manifest's steps (each an argument list), or a problem. One step per line; blank lines
	and # comments are skipped. Each step is a game wrapper that rfs-slot queues on its own."""
	steps = []
	for number, line in enumerate(text.splitlines(), 1):
		line = line.strip()
		if not line or line.startswith("#"):
			continue
		try:
			args = shlex.split(line)
		except ValueError as error:
			return [], f"line {number}: {error}"
		if args[0] not in SHOT_STEPS:
			return [], f"line {number}: a step runs one of {', '.join(sorted(SHOT_STEPS))}"
		if args[0] == "tools/godot.sh" and args[1:] != ["--import"]:
			return [], f"line {number}: tools/godot.sh only as tools/godot.sh --import"
		if any(a in ("&&", "||", ";", "|", ">", "<") for a in args):
			return [], f"line {number}: one command per line, no shell operators"
		steps.append(args)
	if not steps:
		return [], "the manifest lists no steps"
	if len(steps) > SHOT_MAX_STEPS:
		return [], f"{len(steps)} steps: at most {SHOT_MAX_STEPS}"
	return steps, ""


def picture_name(relative: str) -> str:
	"""A published picture's file name: its path under out/ci_shots with / as __, as a .jpg."""
	stem = re.sub(r"[^A-Za-z0-9_.-]", "_", PICTURE.sub("", relative).replace("/", "__"))
	return stem + ".jpg"


def jobs_for(number: int, sha: str, branch: str, message: str) -> list[Job]:
	"""What to run for a PR head: the tests (none for `Box-Test: none`), then any pictures."""
	shots = shots_job(number, sha, branch, message)
	suite = trailer_suite(message)
	if suite is None:
		return [Job(number, sha, branch, "box/landing", LANDING)] + shots
	if suite.lower() == "none":
		return shots
	job = Job(number, sha, branch, "box/test", suite)
	if not SUITE_NAME.match(suite):
		job.problem = "Box-Test names no suite the box can run"
	elif suite in WHOLE_SUITES:
		job.problem = f"the box runs {suite} only inside landing: use Box-Test: landing or a suite folder"
	return [job] + shots


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


def what(job: Job) -> str:
	return f"tools/ci_shots/{job.suite}.txt" if job.context == "box/shots" else f"tools/test.sh {job.suite}"


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


def render_comment(sha: str, results: dict, pictures: list | None = None) -> str:
	icons = {"success": "passed", "failure": "FAILED", "error": "could not run", "pending": "running"}
	out = [MARKER, f"**TrueNAS box tests** for `{sha[:9]}`", ""]
	for context, (state, summary, log_tail) in sorted(results.items()):
		out.append(f"- `{context}`: {icons.get(state, state)}. {summary}")
		if state in ("failure", "error") and log_tail:
			out += ["", "<details><summary>End of the log</summary>", "", "```text", log_tail, "```", "</details>", ""]
	if pictures:
		out += ["", "<details open><summary>Pictures (box/shots)</summary>", ""]
		for name, url in pictures:
			out += [f"`{name}`", "", f'<img src="{url}" width="640">', ""]
		out += ["</details>"]
	out += ["", "Rerun a suite: push a commit with a `Box-Test: SUITE` trailer (`Box-Test: none` skips the box).",
		"Pictures: add `Box-Shot: NAME` to run tools/ci_shots/NAME.txt."]
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
	body = render_comment(state.sha, state.results, state.pictures)
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


STALE_LOCK_S = 120


def clear_stale_locks(lane: str) -> list[str]:
	"""Remove git lock files a killed run left in the lane's git dir (a timed-out suite, or the
	worker's restart, can stop git mid-write). rfs-ci is the only thing that uses its lanes and runs
	one job at a time, so a lock older than STALE_LOCK_S is no one's. Returns what it removed."""
	try:
		gitdir = git("rev-parse", "--absolute-git-dir", cwd=lane).strip()
	except RuntimeError:
		return []
	removed = []
	for name in ("index.lock", "HEAD.lock", "shallow.lock"):
		path = os.path.join(gitdir, name)
		try:
			age = time.time() - os.path.getmtime(path)
		except OSError:
			continue
		if age > STALE_LOCK_S:
			os.remove(path)
			removed.append(path)
			log(f"removed a stale git lock ({age / 60:.0f} min old): {path}")
	return removed


def prepare_lane(job: Job) -> str:
	"""The lane at the job's head, or "" when the branch has moved on (a newer push supersedes it)."""
	lane = lane_dir(job.number)
	if not os.path.isdir(lane):
		subprocess.run(["rfs-lane", "new", f"ci-pr-{job.number}", "--branch", job.branch], check=True,
			env={**os.environ, "TMD_MAIN_CHECKOUT": MAIN})
	clear_stale_locks(lane)
	git("fetch", "-q", "origin", job.branch, cwd=lane)
	if git("rev-parse", f"origin/{job.branch}", cwd=lane).strip() != job.sha:
		return ""
	git("reset", "-q", "--hard", job.sha, cwd=lane)
	git("clean", "-q", "-fd", cwd=lane)  # untracked only; the ignored import cache stays
	subprocess.run(["git", "-C", lane, "lfs", "pull"], check=True)
	# Reflinks of the objects, as rfs-lane makes them, so a lane costs a few GB rather than ~20.
	subprocess.run(["git", "-C", lane, "lfs", "dedup"], capture_output=True)
	return lane


def run_slotted(lane: str, steps: list[list[str]], path: str) -> int | None:
	"""Runs each step through rfs-slot in the lane, in order, into one log; stops at the first that
	fails. The exit code of the last step run, or None when the whole run passed its time limit."""
	env = {k: v for k, v in os.environ.items() if k not in SECRET_ENV}
	# Waits its turn however long the queue is: CI has nobody to hand an exit 75 back to.
	env.update(TMD_SLOT_MAX_WAIT="0", DISPLAY=env.get("DISPLAY", ":99"))
	deadline = time.monotonic() + TIMEOUT_MINUTES * 60
	code: int | None = 0
	with open(path, "w") as out:
		for step in steps:
			if len(steps) > 1:
				out.write(f"$ {shlex.join(step)}\n")
				out.flush()
			proc = subprocess.Popen(["rfs-slot", *step], cwd=lane, env=env,
				stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
			try:
				code = proc.wait(timeout=max(1.0, deadline - time.monotonic()))
			except subprocess.TimeoutExpired:
				os.killpg(proc.pid, signal.SIGTERM)
				try:
					proc.wait(timeout=60)
				except subprocess.TimeoutExpired:
					os.killpg(proc.pid, signal.SIGKILL)
				return None
			if code != 0:
				return code
	return code


def log_path(job: Job) -> str:
	os.makedirs(LOGS, exist_ok=True)
	kind = "shots-" if job.context == "box/shots" else ""
	return f"{LOGS}/pr-{job.number}-{job.sha[:9]}-{kind}{job.suite.replace('/', '_')}.log"


def run_suite(lane: str, job: Job) -> tuple[int | None, str]:
	path = log_path(job)
	code = run_slotted(lane, [["tools/test.sh", job.suite]], path)
	with open(path, errors="replace") as f:
		text = f.read()
	log(f"PR #{job.number} {job.context} {job.suite}: exit {code}, log {path}")
	return code, text


def run_shots(lane: str, job: Job) -> tuple[int | None, str, list[str], str]:
	"""Runs a shots manifest's steps; the exit code, the log, the pictures written (paths under
	out/ci_shots, oldest first) and the manifest's problem, when it is missing or bad (nothing ran)."""
	path = log_path(job)
	manifest = os.path.join(lane, "tools", "ci_shots", f"{job.suite}.txt")
	if not os.path.isfile(manifest):
		return 2, "", [], f"no tools/ci_shots/{job.suite}.txt on the branch"
	with open(manifest, errors="replace") as f:
		steps, problem = parse_manifest(f.read())
	if problem:
		return 2, "", [], f"tools/ci_shots/{job.suite}.txt: {problem}"
	shots = os.path.join(lane, SHOTS_DIR)
	shutil.rmtree(shots, ignore_errors=True)  # out/ is ignored: git clean leaves an older run's
	os.makedirs(shots, exist_ok=True)
	code = run_slotted(lane, steps, path)
	with open(path, errors="replace") as f:
		text = f.read()
	found = []
	for root, _dirs, files in os.walk(shots):
		for name in files:
			if PICTURE.search(name):
				full = os.path.join(root, name)
				found.append((os.path.getmtime(full), os.path.relpath(full, shots)))
	pictures = [rel for _t, rel in sorted(found)]
	log(f"PR #{job.number} box/shots {job.suite}: exit {code}, {len(pictures)} pictures, log {path}")
	return code, text, pictures, ""


def review_copy(src: str, dst: str) -> bool:
	"""Writes a review-size JPG of a picture; False when it can't (no Pillow and too big)."""
	try:
		from PIL import Image
	except ImportError:
		if os.path.getsize(src) > SHOT_MAX_BYTES:
			return False
		shutil.copyfile(src, dst)  # named .jpg but may be a PNG: browsers sniff the bytes
		return True
	try:
		with Image.open(src) as image:
			image = image.convert("RGB")
			if image.width > SHOT_WIDTH:
				image = image.resize((SHOT_WIDTH, round(image.height * SHOT_WIDTH / image.width)), Image.LANCZOS)
			image.save(dst, "JPEG", quality=85, optimize=True)
	except OSError:  # not a picture after all (a half-written render)
		return False
	return True


def shots_url(number: int, sha: str, name: str) -> str:
	return f"https://github.com/{REPO}/blob/{SHOTS_BRANCH}/ci/pr-{number}/{sha[:9]}/{name}?raw=true"


def publish_shots(lane: str, job: Job, pictures: list[str]) -> tuple[list, str]:
	"""Pushes review copies of the pictures to the shots branch; (name, url) pairs and a note on any
	left out. A small clone of that branch alone lives beside the lanes."""
	clone = f"{ROOT}/rfs-ci-shots"
	if not os.path.isdir(f"{clone}/.git"):
		shutil.rmtree(clone, ignore_errors=True)
		git("clone", "-q", "--depth", "1", "--single-branch", "--branch", SHOTS_BRANCH,
			SHOTS_REMOTE, clone, cwd=ROOT)
	git("fetch", "-q", "--depth", "1", "origin", SHOTS_BRANCH, cwd=clone)
	git("reset", "-q", "--hard", f"origin/{SHOTS_BRANCH}", cwd=clone)
	folder = f"ci/pr-{job.number}/{job.sha[:9]}"
	target = os.path.join(clone, folder)
	shutil.rmtree(target, ignore_errors=True)
	os.makedirs(target)
	published, skipped = [], []
	for rel in pictures[:SHOT_MAX_FILES]:
		name = picture_name(rel)
		if review_copy(os.path.join(lane, SHOTS_DIR, rel), os.path.join(target, name)):
			published.append((name, shots_url(job.number, job.sha, name)))
		else:
			skipped.append(rel)
	note = ""
	if len(pictures) > SHOT_MAX_FILES:
		note = f" {len(pictures) - SHOT_MAX_FILES} more left out (at most {SHOT_MAX_FILES})."
	if skipped:
		note += f" Too big to publish without Pillow: {', '.join(skipped[:5])}."
	if not published:
		return [], note
	git("add", "-A", folder, cwd=clone)
	if not git("status", "--porcelain", cwd=clone).strip():
		return published, note  # the same pictures are there already (a rerun of the same head)
	git("-c", "user.name=rfs-ci", "-c", "user.email=rfs-ci@users.noreply.github.com", "commit", "-q",
		"-m", f"box/shots for PR #{job.number} at {job.sha[:9]}", cwd=clone)
	for attempt in range(3):  # another publish may have moved the branch: replay ours on it
		try:
			git("push", "-q", "origin", f"HEAD:{SHOTS_BRANCH}", cwd=clone)
			break
		except RuntimeError:
			if attempt == 2:
				raise
			git("fetch", "-q", "--depth", "1", "origin", SHOTS_BRANCH, cwd=clone)
			git("rebase", "-q", f"origin/{SHOTS_BRANCH}", cwd=clone)
	return published, note


def run(job: Job) -> None:
	state = prs[job.number]
	if job.problem:
		set_status(job.sha, job.context, "error", job.problem)
		state.results[job.context] = ("error", job.problem, "")
		upsert_comment(job.number, state)
		return
	set_status(job.sha, job.context, "pending", f"{what(job)}: waiting for a box slot")
	try:
		lane = prepare_lane(job)
	except (RuntimeError, subprocess.CalledProcessError) as error:
		set_status(job.sha, job.context, "error", f"couldn't check out the branch on the box: {error}")
		log(f"PR #{job.number}: lane failed: {error}")
		return
	if not lane:
		set_status(job.sha, job.context, "error", "superseded by a newer push before its turn")
		return
	if job.context == "box/shots":
		run_pictures(lane, job, state)
		return
	code, text = run_suite(lane, job)
	verdict = outcome(code)
	summary = f"timed out after {TIMEOUT_MINUTES} min" if code is None else summary_line(text)
	set_status(job.sha, job.context, verdict, summary)
	if state.sha == job.sha:
		state.results[job.context] = (verdict, summary, tail(text) if verdict != "success" else "")
		upsert_comment(job.number, state)


def run_pictures(lane: str, job: Job, state: PrState) -> None:
	code, text, pictures, problem = run_shots(lane, job)
	verdict = outcome(code)
	if problem:
		verdict, summary = "error", problem
	elif code is None:
		summary = f"timed out after {TIMEOUT_MINUTES} min"
	elif code != 0:
		summary = f"a step failed: {summary_line(text)}"
	else:
		summary = f"{len(pictures)} pictures from tools/ci_shots/{job.suite}.txt"
	published, note = [], ""
	if pictures:
		try:
			published, note = publish_shots(lane, job, pictures)
		except (RuntimeError, OSError) as error:
			note = f" Couldn't publish them: {describe(str(error), 200)} (the token needs Contents RW)."
			if verdict == "success":
				verdict = "error"
		if verdict == "success" and not published:
			verdict = "error"
	elif verdict == "success":
		verdict, summary = "error", f"tools/ci_shots/{job.suite}.txt wrote no pictures under {SHOTS_DIR}"
	set_status(job.sha, job.context, verdict, summary)
	if state.sha == job.sha:
		state.pictures = published
		state.results[job.context] = (verdict, summary + note, tail(text) if verdict != "success" else "")
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
		state.sha, state.results, state.pictures = sha, {}, []
		state.jobs = [j for j in jobs_for(number, sha, branch, message) if done.get(j.context) in (None, "pending")]
		for job in state.jobs:
			set_status(sha, job.context, "pending", f"{what(job)}: queued on the TrueNAS box")
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
