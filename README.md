# agent-runner

Label a GitHub issue `agent` and a Claude Managed Agent works it on the TrueNAS box and opens a
pull request. The agent loop runs on Anthropic's side and is billed to the Console API credits;
the agent's tools (bash, files, git, Godot) run in a container on TrueNAS.

## How it works

```
issue gets label "agent"
  -> GitHub Action mints an OIDC token (audience https://api.anthropic.com)
  -> Anthropic exchanges it for a short-lived key (federation rule -> service account)
  -> Action creates a session with a hard budget and the message "Work issue #N in owner/repo"
  -> worker on TrueNAS (outbound polling, no open ports) picks up the work
  -> agent clones the repo, follows its CLAUDE.md / CONTRIBUTING.md, tests, pushes a branch,
     opens a PR, comments on the issue
```

No API key is stored in GitHub. The only long-lived secrets are the worker's environment key and
GitHub token, both on the TrueNAS box.

## Layout

| Path | What |
|---|---|
| `agents/repo-agent.md` | The agent: model, tools, and the system prompt (rules of engagement) |
| `environments/truenas.yaml` | The self-hosted environment definition |
| `worker/` | Dockerfile, compose file and entrypoint for the TrueNAS worker |
| `deploy/` | Script and compose template that install the worker as a TrueNAS custom app |
| `github/agent.yml`, `github/start-session.ts` | Copy into a repo as `.github/workflows/agent.yml` and `.github/agent/start-session.ts` |

Already installed in `RigForSilent` (merged).

## Setup

Done already in Console: the `github-actions` issuer, the `github-agent` service account and the
federation rule (`repo:derekhearst/*`). The IDs are in `github/agent.yml`. The workflow is merged
into RigForSilent (PR 141).

1. **Create the agent and environment.** Install `ant` (1.40.0 or later, from the
   [releases page](https://github.com/anthropics/anthropic-cli/releases)) and run `ant auth login`,
   then from this folder:
   ```bash
   ant apply --dry-run -v environments/truenas.yaml agents/repo-agent.md
   ant apply environments/truenas.yaml agents/repo-agent.md
   ```
   This writes `claude-lock.json` with the agent ID (`agent_...`) and environment ID (`env_...`).
   Log in under the **same workspace** the service account uses (Default), or the agent will not
   be visible to the Action.
2. **Environment key.** Console > Environments > `truenas-worker` > Generate environment key.
3. **GitHub token.** A fine-grained PAT for only the repos the agent may touch. Repository
   permissions: Contents RW, Issues RW, Pull requests RW, Metadata R. Do not give it admin or
   workflow permissions.
4. **Start the worker on TrueNAS.** The box has no usable `docker` CLI (sudo needs a password), so
   it runs as a custom app that pulls `ghcr.io/derekhearst/agent-runner-worker`, built by
   `.github/workflows/image.yml` on every push to `worker/`. Then:
   ```bash
   cp worker/.env.example deploy/.env   # fill in the environment key, env ID, GitHub token, git email
   deploy/deploy.sh                     # creates or updates the `agent-runner` app over SSH
   deploy/deploy.sh restart             # after a new image is published
   ```
   Logs are in the TrueNAS UI: Apps > agent-runner > Logs. `worker/compose.yaml` is the same
   container for a machine where docker works (`docker compose up -d --build`).
5. **Repo variables** (Settings > Secrets and variables > Actions > Variables) in each repo:
   `ANTHROPIC_AGENT_ID`, `ANTHROPIC_ENVIRONMENT_ID`, and optionally `AGENT_BUDGET_USD`
   (default 10, a hard cap per session).
6. **Create the `agent` label** in the repo, then add it to a small issue to test.

For another repo, copy the two GitHub files, add the repo to the PAT, and set the variables. The
federation rule already matches every `derekhearst/*` repo.

## Cost and safety

- Each session has a hard dollar cap (`AGENT_BUDGET_USD`). At the cap it pauses; it is not
  silently overspent. List cost is tokens plus about $0.08 per session-hour.
- Only people with triage access can add a label, so only they can start the agent. Issue text is
  treated as data by the agent, never as instructions.
- The worker container has no root, no Linux capabilities and no Docker socket. Its blast radius is
  the GitHub token (scoped repos only) and the container's own network access. Egress is not
  restricted by default; tighten it in the TrueNAS firewall if you want.
- The agent never merges and never pushes to the default branch; you review every PR.
- Web search and fetch are off for the agent.

## Not verified yet

Written from the docs, not yet run end to end:

- `ant beta:worker poll --max-idle` (default 1m) stops the work for a *session* that has been idle
  after finishing a turn; it should not end the worker, but watch the first logs to confirm.
- RigForSilent's first session will download Godot 4.7.2 into the `rfs-tools` volume via
  `tools/bootstrap.sh` and may need a long first import; the per-command time limits are in that
  repo's `docs/SETUP.md`.
