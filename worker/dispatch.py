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
import urllib.request
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


# --- usage report -----------------------------------------------------------------------------
# Every STATS_EVERY_SECONDS, sends the token usage of all this agent's sessions to the Claude usage
# dashboard (tools/claude-stats) as its own source. Each push replaces that source's data, so a
# missed or repeated push is harmless. Off unless CLAUDE_STATS_TOKEN is set.

STATS_URL = os.environ.get("CLAUDE_STATS_URL", "https://usage.derekhearst.com").rstrip("/")
STATS_TOKEN = os.environ.get("CLAUDE_STATS_TOKEN", "")
STATS_SOURCE = os.environ.get("CLAUDE_STATS_SOURCE", "agent-runner")
STATS_EVERY_SECONDS = int(os.environ.get("CLAUDE_STATS_EVERY_SECONDS", "3600"))
last_stats_push = 0.0


def _num(obj: object, name: str) -> int:
	value = obj.get(name) if isinstance(obj, dict) else getattr(obj, name, None)
	return int(value or 0)


def usage_snapshot(sessions: list, source: str, tz) -> dict:
	"""A dashboard snapshot from sessions (the shape tools/claude-stats/collector sends). Pure, so it is tested.

	Sessions only report cumulative usage, so a session's tokens all land on the day it was created."""
	daily: dict[str, dict] = {}
	day_tokens: dict[tuple[str, str], int] = {}
	models: dict[str, dict] = {}
	projects: dict[tuple[str, str], dict] = {}
	first = None
	for session in sessions:
		usage = getattr(session, "usage", None)
		if usage is None:
			continue
		model = getattr(getattr(session.agent, "model", None), "id", None) or "unknown"
		repo = (session.metadata or {}).get("repo", "") or "(no repo)"
		cache = getattr(usage, "cache_creation", None)
		row = {
			"input": _num(usage, "input_tokens"),
			"output": _num(usage, "output_tokens"),
			"cacheRead": _num(usage, "cache_read_input_tokens"),
			"cacheCreate": _num(cache, "ephemeral_5m_input_tokens") + _num(cache, "ephemeral_1h_input_tokens"),
		}
		date = session.created_at.astimezone(tz).date().isoformat()
		first = min(first, session.created_at) if first else session.created_at
		daily.setdefault(date, {"date": date, "messages": 0, "sessions": 0, "tool_calls": 0})["sessions"] += 1
		day_tokens[(date, model)] = day_tokens.get((date, model), 0) + row["input"] + row["output"]
		for bucket in (models.setdefault(model, dict.fromkeys(row, 0)), projects.setdefault((repo, model), dict.fromkeys(row, 0))):
			for key, value in row.items():
				bucket[key] += value
	return {
		"source": source,
		"firstSession": first.isoformat() if first else None,
		"daily": list(daily.values()),
		"dailyModelTokens": [{"date": d, "model": m, "tokens": t} for (d, m), t in day_tokens.items() if t > 0],
		"modelUsage": [{"model": m, **u} for m, u in models.items()],
		"projectUsage": [{"project": p, "model": m, **u} for (p, m), u in projects.items()],
	}


def push_usage(client: anthropic.Anthropic) -> None:
	global last_stats_push
	if not STATS_TOKEN or time.time() - last_stats_push < STATS_EVERY_SECONDS:
		return
	last_stats_push = time.time()  # also on failure, so an outage costs one try per interval
	try:
		from zoneinfo import ZoneInfo
		tz = ZoneInfo(os.environ.get("CLAUDE_STATS_TZ", "America/Boise"))
	except Exception:  # noqa: BLE001 - no tz database in the image: fall back to UTC days
		tz = timezone.utc
	sessions = list(client.beta.sessions.list(agent_id=AGENT_ID, limit=100))  # iterating auto-paginates
	body = json.dumps(usage_snapshot(sessions, STATS_SOURCE, tz)).encode()
	request = urllib.request.Request(
		STATS_URL + "/ingest", data=body, method="POST",
		# Cloudflare tends to refuse Python's default user agent, so name ours.
		headers={"content-type": "application/json", "authorization": "Bearer " + STATS_TOKEN, "user-agent": "agent-runner-dispatcher"},
	)
	with urllib.request.urlopen(request, timeout=30) as response:
		log(f"usage pushed to {STATS_URL}: {len(sessions)} sessions -> {response.read().decode()[:120]}")


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
		try:
			push_usage(client)
		except Exception as error:  # noqa: BLE001 - the dashboard is a nicety; never stop the loop for it
			log(f"usage push failed: {error}")
		if once:
			return
		time.sleep(POLL_SECONDS)


if __name__ == "__main__":
	main()
