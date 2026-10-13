"""Starts a Managed Agents session for every GitHub issue labelled `agent`.

Runs on the TrueNAS box as its own container (not the worker's), so the Anthropic API key here is
never reachable from the agent's tools. Every POLL_SECONDS it asks GitHub for open issues
labelled TRIGGER_LABEL under GITHUB_OWNER. For each one it swaps the label to RUNNING_LABEL
first (so a crash can't start it twice), then creates the session and comments the link.
If starting fails, it comments the error and labels the issue FAILED_LABEL; add `agent` again to retry.
"""
import json
import os
import subprocess
import sys
import time

import anthropic

OWNER = os.environ.get("GITHUB_OWNER", "derekhearst")
TRIGGER_LABEL = os.environ.get("TRIGGER_LABEL", "agent")
RUNNING_LABEL = os.environ.get("RUNNING_LABEL", "agent: started")
FAILED_LABEL = os.environ.get("FAILED_LABEL", "agent: failed")
POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "60"))
BUDGET_USD = float(os.environ.get("BUDGET_USD", "10"))
AGENT_ID = os.environ["AGENT_ID"]
ENVIRONMENT_ID = os.environ["ENVIRONMENT_ID"]
CONSOLE_URL = "https://platform.claude.com/workspaces/default/sessions"


def log(message: str) -> None:
	print(time.strftime("%H:%M:%S"), message, flush=True)


def gh(*args: str) -> str:
	result = subprocess.run(["gh", *args], capture_output=True, text=True)
	if result.returncode != 0:
		raise RuntimeError(f"gh {' '.join(args[:3])} failed: {result.stderr.strip()[:300]}")
	return result.stdout


def labelled_issues() -> list[tuple[str, int]]:
	query = f'is:issue is:open label:"{TRIGGER_LABEL}" user:{OWNER}'
	out = gh("api", "-X", "GET", "search/issues", "-f", f"q={query}", "-f", "per_page=20")
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
	url = f"{CONSOLE_URL}/{session.id}"
	log(f"started {session.id} for {repo}#{number}")
	comment(repo, number, f"Agent session started: {url}")


def main() -> None:
	client = anthropic.Anthropic()  # reads ANTHROPIC_API_KEY
	once = "--once" in sys.argv
	log(f"watching {OWNER}'s issues labelled {TRIGGER_LABEL!r} every {POLL_SECONDS}s, budget ${BUDGET_USD:.2f}/session")
	while True:
		try:
			for repo, number in labelled_issues():
				start(client, repo, number)
		except Exception as error:  # noqa: BLE001 - keep the loop alive through GitHub/network blips
			log(f"poll failed: {error}")
		if once:
			return
		time.sleep(POLL_SECONDS)


if __name__ == "__main__":
	main()
