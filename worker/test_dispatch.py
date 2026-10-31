"""Tests for the dispatcher's supervision rules. Run: AGENT_ID=a ENVIRONMENT_ID=e python test_dispatch.py"""
import os

os.environ.setdefault("AGENT_ID", "agent_test")
os.environ.setdefault("ENVIRONMENT_ID", "env_test")

import dispatch  # noqa: E402

STALL = dispatch.STALL_MINUTES * 60
MAX = dispatch.MAX_RECOVERIES


def check(name: str, got: str, want: str) -> None:
	assert got == want, f"{name}: got {got!r}, want {want!r}"
	print("ok  ", name)


# running or rescheduling: the platform is on it
check("running", dispatch.decide("running", None, 99999, 0), "ok")
check("rescheduling", dispatch.decide("rescheduling", None, 99999, 0), "ok")
# a long tool call is normal; only a long silence is a stall
check("waiting on a tool, recent", dispatch.decide("idle", "requires_action", STALL - 1, 0), "ok")
check("waiting on a tool, silent", dispatch.decide("idle", "requires_action", STALL, 0), "recover")
check("second stall recovers again", dispatch.decide("idle", "requires_action", STALL, MAX - 1), "recover")
check("recoveries used up -> stuck", dispatch.decide("idle", "requires_action", STALL, MAX), "stuck")
# finished: the turn ended and stayed ended
check("end_turn just now (between turns)", dispatch.decide("idle", "end_turn", 10, 0), "ok")
check("end_turn and quiet", dispatch.decide("idle", "end_turn", dispatch.FINISHED_AFTER_SECONDS, 0), "done")
check("no stop reason and quiet", dispatch.decide("idle", None, 600, 0), "done")
# the rest
check("budget", dispatch.decide("idle", "budget_reached", 5, 0), "budget")
check("terminated", dispatch.decide("terminated", None, 5, 0), "failed")

# usage snapshot for the dashboard: tokens summed per model and repo, sessions counted per day
from datetime import datetime, timezone  # noqa: E402
from types import SimpleNamespace as NS  # noqa: E402


def session(created: str, repo: str, inp: int, out: int, read: int, five: int) -> NS:
	return NS(
		created_at=datetime.fromisoformat(created),
		metadata={"repo": repo, "issue": "1"},
		agent=NS(model=NS(id="claude-opus-5-5")),
		usage=NS(input_tokens=inp, output_tokens=out, cache_read_input_tokens=read,
			cache_creation=NS(ephemeral_5m_input_tokens=five, ephemeral_1h_input_tokens=0)),
	)


snap = dispatch.usage_snapshot([
	session("2026-10-13T08:00:00+00:00", "o/a", 10, 20, 3_000_000_000, 5),
	session("2026-10-13T09:00:00+00:00", "o/b", 1, 2, 3, 4),
], "agent-runner", timezone.utc)
check("one day", str(snap["daily"]), str([{"date": "2026-10-13", "messages": 0, "sessions": 2, "tool_calls": 0}]))
check("model totals", str(snap["modelUsage"]), str([{"model": "claude-opus-5-5", "input": 11, "output": 22, "cacheRead": 3_000_000_003, "cacheCreate": 9}]))
check("per repo", str(len(snap["projectUsage"])), "2")
check("day tokens are input + output", str(snap["dailyModelTokens"][0]["tokens"]), "33")
print("all passed")
