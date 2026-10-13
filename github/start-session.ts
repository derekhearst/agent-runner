// Starts a Managed Agents session for one GitHub issue. Run by .github/workflows/agent.yml.
// Auth is Workload Identity Federation: the SDK reads the ANTHROPIC_* federation variables and
// the OIDC token file, exchanges the token, and refreshes it. No API key is stored anywhere.
import { appendFileSync } from "node:fs";
import Anthropic from "@anthropic-ai/sdk@0.133.0";

const need = (name: string): string => {
	const value = process.env[name];
	if (!value) throw new Error(`${name} is not set`);
	return value;
};

const repo = need("REPO");
const issue = need("ISSUE_NUMBER");
const budgetUsd = Number(process.env.BUDGET_USD ?? "10");

const client = new Anthropic();

// Only the repo and issue number go in the prompt. The issue text is untrusted, so the agent
// reads it itself and treats it as data (see agents/repo-agent.md).
const session = await client.beta.sessions.create({
	agent: need("AGENT_ID"),
	environment_id: need("ENVIRONMENT_ID"),
	title: `${repo}#${issue}`,
	budget: {
		type: "limit",
		max_list_cost: { amount: String(Math.round(budgetUsd * 100)), currency: "USD" },
	},
	metadata: { repo, issue },
	initial_events: [
		{
			type: "user.message",
			content: [{ type: "text", text: `Work GitHub issue #${issue} in ${repo}.` }],
		},
	],
});

const url = `https://platform.claude.com/workspaces/default/sessions/${session.id}`;
console.log(`Started ${session.id} (${session.status})\n${url}`);
if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `url=${url}\nid=${session.id}\n`);
