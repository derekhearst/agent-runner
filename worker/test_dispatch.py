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
print("all passed")
