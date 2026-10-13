"""Starts a Managed Agents session for every GitHub issue labelled `agent`, then keeps watching it.

Runs on the TrueNAS box as its own container (not the worker's), so the Anthropic API key here is
never reachable from the agent's tools. Every POLL_SECONDS it does two things:

1. Dispatch: for each open issue labelled TRIGGER_LABEL under GITHUB_OWNER, swap the label to
   RUNNING_LABEL first (so a crash can't start it twice), create the session, comment the link.
   If starting fails: comment the error and label FAILED_LABEL; add `agent` again to retry.

2. Supervise: for each open issue labelled RUNNING_LABEL, look at its newest session and
   - recover a session whose sandbox connection dropped (idle + requires_action for STALL_MINUTES):
     interrupt it so the platform re-queues the lost work, then tell it to carry on. After
     MAX_RECOVERIES tries without progress, label the issue STUCK_LABEL and say so.
   - finish: when the session ends its turn, comment the cost and label DONE_LABEL.
   - report: budget reached -> BUDGET_LABEL; terminated -> FAILED_LABEL; worker offline -> a comment.
Nothing needs babysitting: every outcome ends as a label and a comment on the issue.
"""
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

import anthropic

OWNER = os.environ.get("GITHUB_OWNER", "derekhearst")
TRIGGER_LABEL = os.environ.get("TRIGGER_LABEL", "agent")
RUNNING_LABEL = os.environ.get("RUNNING_LABEL", "agent: started")
FAILED_LABEL = os.environ.get("FAILED_LABEL", "agent: failed")
DONE_LABEL = os.environ.get("DONE_LABEL", "agent: done")
STUCK_LABEL = os.environ.get("STUCK_LABEL", "agent: stuck")
BUDGET_LABEL = os.environ.get("BUDGET_LABEL", "agent: budget")
POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "60"))
BUDGET_USD = float(os.environ.get("BUDGET_USD", "10"))
STALL_MINUTES = int(os.environ.get("STALL_MINUTES", "25"))
MAX_RECOVERIES = int(os.environ.get("MAX_RECOVERIES", "2"))
FINISHED_AFTER_SECONDS = 120
AGENT_ID = os.environ["AGENT_ID"]
ENVIRONMENT_ID = os.environ["ENVIRONMENT_ID"]
CONSOLE_URL = "https://platform.claude.com/workspaces/default/sessions"

RECOVERY_MESSAGE = (
	"Your sandbox connection dropped, so your last tool call was lost. The files on disk are intact. "
	"Check the state of your work (git status, any detached run's log) and carry on from where you "
	"left off. Keep every tool call short (under about two minutes) and run anything longer detached, "
	"so a dropped connection costs at most one poll."
)

# Remembered between cycles (the container is stateless otherwise; GitHub labels are the real state).
recoveries: dict[str, tuple[str, int]] = {}  # session id -> (updated_at when last recovered, count)
offline_cycles = 0
offline_notified: set[tuple[str, int]] = set()


def log(message: str) -> None:
	print(time.strftime("%H:%M:%S"), message, flush=True)


def gh(*args: str) -> str:
	result = subprocess.run(["gh", *args], capture_output=True, text=True)
	if result.returncode != 0:
		raise RuntimeError(f"gh {' '.join(args[:3])} failed: {result.stderr.strip()[:300]}")
	return result.stdout


def issues_labelled(label: str) -> list[tuple[str, int]]:
	query = f'is:issue is:open label:"{label}" user:{OWNER}'
	out = gh("api", "-X", "GET", "search/issues", "-f", f"q={query}", "-f", "per_page=30")
	found = []
	for item in json.loads(out)["items"]:
		repo = item["repository_url"].removeprefix("https://api.github.com/repos/")
		found.append((repo, item["number"]))
	return found


def swap_label(repo: str, number: int, remove: str, add: str) -> None:
	try:
		gh("api", "-X", "DELETE", f"repos/{repo}/issues/{number}/labels/{remove}")
	except RuntimeError as error:
		log(f"could not remove label {remove!r} on {repo}#{number}: {error}")
	gh("api", f"repos/{repo}/issues/{number}/labels", "-f", f"labels[]={add}")


def comment(repo: str, number: int, body: str) -> None:
	gh("api", f"repos/{repo}/issues/{number}/comments", "-f", f"body={body}")


# --- dispatch ---------------------------------------------------------------------------------


def start(client: anthropic.Anthropic, repo: str, number: int) -> None:
	log(f"dispatching {repo}#{number}")
	swap_label(repo, number, TRIGGER_LABEL, RUNNING_LABEL)
	try:
		# Only the repo and issue number go in the prompt: issue text is untrusted, so the agent
		# reads it itself and treats it as data (see agents/repo-agent.md).
		session = client.beta.sessions.create(
			agent=AGENT_ID,
			environment_id=ENVIRONMENT_ID,
			title=f"{repo}#{number}",
			budget={
				"type": "limit",
				"max_list_cost": {"amount": str(round(BUDGET_USD * 100)), "currency": "USD"},
			},
			metadata={"repo": repo, "issue": str(number)},
			initial_events=[
				{
					"type": "user.message",
					"content": [{"type": "text", "text": f"Work GitHub issue #{number} in {repo}."}],
				}
			],
		)
	except Exception as error:  # noqa: BLE001 - report any failure on the issue, then move on
		log(f"session create failed for {repo}#{number}: {error}")
		swap_label(repo, number, RUNNING_LABEL, FAILED_LABEL)
		comment(repo, number, f"Could not start the agent: `{type(error).__name__}`. Add the `{TRIGGER_LABEL}` label to retry.")
		return
	log(f"started {session.id} for {repo}#{number}")
	comment(repo, number, f"Agent session started: {CONSOLE_URL}/{session.id}")


# --- supervise --------------------------------------------------------------------------------


def decide(status: str, stop_reason: str | None, age_seconds: float, recoveries_used: int) -> str:
	"""What to do about a session: ok | recover | stuck | done | budget | failed. Pure, so it is tested."""
	if status == "terminated":
		return "failed"
	if status != "idle":
		return "ok"  # running or rescheduling: the platform is working on it
	if stop_reason == "budget_reached":
		return "budget"
	if stop_reason == "requires_action":
		if age_seconds < STALL_MINUTES * 60:
			return "ok"  # a long tool call is normal; only a long silence is a stall
		return "recover" if recoveries_used < MAX_RECOVERIES else "stuck"
	return "done" if age_seconds >= FINISHED_AFTER_SECONDS else "ok"


def newest_sessions(client: anthropic.Anthropic) -> dict[tuple[str, str], object]:
	"""The newest session per (repo, issue), from the metadata set at creation (follow-ups carry it too)."""
	newest: dict[tuple[str, str], object] = {}
	page = client.beta.sessions.list(agent_id=AGENT_ID, order="desc", limit=100)
	for session in page.data:
		meta = session.metadata or {}
		key = (meta.get("repo", ""), meta.get("issue", ""))
		if key[0] and key not in newest:
			newest[key] = session
	return newest


def last_stop_reason(client: anthropic.Anthropic, session_id: str) -> str | None:
	page = client.beta.sessions.events.list(session_id, order="desc", limit=5, types=["session.status_idle"])
	for event in page.data:
		stop = getattr(event, "stop_reason", None)
		return getattr(stop, "type", None)
	return None


def cost_text(session: object) -> str:
	try:
		return f"${int(session.usage.list_cost.amount) / 100:.2f}"
	except Exception:  # noqa: BLE001 - cost is a nicety
		return "unknown cost"


def supervise(client: anthropic.Anthropic) -> None:
	global offline_cycles
	active = issues_labelled(RUNNING_LABEL)
	if not active:
		offline_cycles = 0
		return
	sessions = newest_sessions(client)
	now = datetime.now(timezone.utc)
	for repo, number in active:
		session = sessions.get((repo, str(number)))
		if session is None:
			continue  # not started by this agent, or older than the newest 100 sessions
		link = f"{CONSOLE_URL}/{session.id}"
		age = (now - session.updated_at).total_seconds()
		marker, used = recoveries.get(session.id, ("", 0))
		if marker and marker != session.updated_at.isoformat() and age < STALL_MINUTES * 60:
			used = 0  # it made progress since the last recovery: a new stall gets a fresh count
			recoveries.pop(session.id, None)
		stop = last_stop_reason(client, session.id) if session.status == "idle" else None
		action = decide(session.status, stop, age, used)
		if action == "ok":
			continue
		log(f"{repo}#{number} {session.id}: {action} (status={session.status}, stop={stop}, age={age:.0f}s)")
		if action == "recover":
			client.beta.sessions.events.send(session.id, events=[{"type": "user.interrupt"}])
			time.sleep(5)  # the interrupt ends the turn; the message below starts the next one
			client.beta.sessions.events.send(
				session.id,
				events=[{"type": "user.message", "content": [{"type": "text", "text": RECOVERY_MESSAGE}]}],
			)
			recoveries[session.id] = (session.updated_at.isoformat(), used + 1)
			comment(repo, number, f"The agent's sandbox connection dropped (no activity for {age / 60:.0f} min). Recovered it automatically (attempt {used + 1} of {MAX_RECOVERIES}): {link}")
		elif action == "stuck":
			swap_label(repo, number, RUNNING_LABEL, STUCK_LABEL)
			comment(repo, number, f"The agent is stuck: no activity for {age / 60:.0f} min and {MAX_RECOVERIES} automatic recoveries did not get it moving. Needs a look: {link}. Add the `{TRIGGER_LABEL}` label to start a fresh session.")
		elif action == "done":
			swap_label(repo, number, RUNNING_LABEL, DONE_LABEL)
			comment(repo, number, f"The agent finished ({cost_text(session)} of the ${BUDGET_USD:.0f} cap). Its summary and any pull request are in the comments above: {link}")
		elif action == "budget":
			swap_label(repo, number, RUNNING_LABEL, BUDGET_LABEL)
			comment(repo, number, f"The agent stopped at its ${BUDGET_USD:.0f} spend cap ({cost_text(session)}) before finishing. Its work so far is on its branch. Raise the cap to continue: {link}")
		elif action == "failed":
			swap_label(repo, number, RUNNING_LABEL, FAILED_LABEL)
			comment(repo, number, f"The agent session ended with an error: {link}. Add the `{TRIGGER_LABEL}` label to retry.")
	check_worker(client, active)


def check_worker(client: anthropic.Anthropic, active: list[tuple[str, int]]) -> None:
	"""Work waiting but nobody polling for 3 cycles means the worker is down: say so once per issue."""
	global offline_cycles
	stats = client.beta.environments.work.stats(ENVIRONMENT_ID)
	waiting = (stats.depth or 0) > 0 or (stats.pending or 0) > 0
	if stats.workers_polling == 0 and waiting:
		offline_cycles += 1
	else:
		offline_cycles = 0
		offline_notified.clear()
		return
	if offline_cycles >= 3:
		for repo, number in active:
			if (repo, number) not in offline_notified:
				offline_notified.add((repo, number))
				comment(repo, number, "The TrueNAS worker is offline (work is waiting and nothing is polling). The agent will carry on by itself when the worker is back.")


def main() -> None:
	client = anthropic.Anthropic()  # reads ANTHROPIC_API_KEY
	once = "--once" in sys.argv
	log(f"watching {OWNER}'s issues labelled {TRIGGER_LABEL!r} every {POLL_SECONDS}s, budget ${BUDGET_USD:.2f}/session, stall {STALL_MINUTES} min")
	while True:
		try:
			for repo, number in issues_labelled(TRIGGER_LABEL):
				start(client, repo, number)
		except Exception as error:  # noqa: BLE001 - keep the loop alive through GitHub/network blips
			log(f"dispatch failed: {error}")
		try:
			supervise(client)
		except Exception as error:  # noqa: BLE001
			log(f"supervise failed: {error}")
		if once:
			return
		time.sleep(POLL_SECONDS)


if __name__ == "__main__":
	main()
