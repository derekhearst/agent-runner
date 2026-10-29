# agent-runner

Label a GitHub issue `agent` and a Claude Managed Agent works it on the TrueNAS box and opens a
pull request. The agent loop runs on Anthropic's side and is billed to the Console API credits;
the agent's tools (bash, files, git, Godot) run in a container on TrueNAS.

## How it works

```
issue gets label "agent"
  -> dispatcher container on TrueNAS (polls GitHub every 60 s) sees it
  -> swaps the label to "agent: started", creates a session with a hard budget, comments the link
  -> the sandbox worker in the dev box container on TrueNAS (outbound polling) picks up the work
  -> agent clones the repo, follows its CLAUDE.md / CONTRIBUTING.md, tests, pushes a branch,
     opens a PR, comments on the issue
```

Everything runs on the TrueNAS box, so no GitHub Actions minutes are used (RigForSilent's own CI
had exhausted the account's Actions budget, which blocked the original Actions trigger).

**Nothing needs babysitting.** The dispatcher also supervises every session it started, and every
outcome ends as a label and a comment on the issue:

| Situation | What it does | Label |
|---|---|---|
| Finished | Comments the cost | `agent: done` |
| Sandbox connection dropped (no activity 25 min while waiting on a tool) | Interrupts the session so the platform re-queues the lost work, tells the agent to carry on, comments. Up to 2 tries. | stays `agent: started` |
| Still stuck after 2 recoveries | Comments with the session link | `agent: stuck` |
| Hit the dollar cap | Comments | `agent: budget` |
| Session ended with an error, or could not start | Comments | `agent: failed` |
| Worker offline (work waiting, nobody polling, 3 min) | Comments once per issue | unchanged |

Add `agent` again to start a fresh session after `stuck`, `failed` or `budget`. The agent's own
prompt also tells it to keep tool calls short, detach long runs, and comment before it ever goes quiet.

The dispatcher and the worker are in separate containers on purpose: the dispatcher holds an Anthropic
API key, and the agent's shell commands run with the worker, which never sees it. The worker holds the
environment key and GitHub token. If starting a session fails the issue is labelled `agent: failed`;
add `agent` again to retry.

> **Superseded:** `github/agent.yml` (an Actions trigger using workload identity federation) still
> works if the Actions budget allows it, but run only one trigger at a time or an issue starts twice.
> The RigForSilent copy is disabled.

## Layout

| Path | What |
|---|---|
| `agents/repo-agent.md` | The agent: model, tools, and the system prompt (rules of engagement) |
| `environments/truenas.yaml` | The self-hosted environment definition |
| `worker/` | Dockerfile, compose file and entrypoints for the TrueNAS worker and the SSH dev box |
| `deploy/` | Script and compose template that install the worker as a TrueNAS custom app |
| `worker/dispatch.py` | The dispatcher (runs in its own container from the same image) |
| `github/` | The older Actions-based trigger, kept for reference |

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
3. **Anthropic API key** for the dispatcher: Console > API keys > Create key, Default workspace.
4. **GitHub token.** A fine-grained PAT for only the repos the agent may touch. Repository
   permissions: Contents RW, Issues RW, Pull requests RW, Metadata R. Do not give it admin or
   workflow permissions.
5. **Start the app on TrueNAS.** The box has no usable `docker` CLI (sudo needs a password), so
   it runs as a custom app that pulls `ghcr.io/derekhearst/agent-runner-worker`, built by
   `.github/workflows/image.yml` on every push to `worker/`. Then:
   ```bash
   cp worker/.env.example deploy/.env   # fill in the environment key, env ID, GitHub token, git email
   deploy/deploy.sh                     # creates or updates the `agent-runner` app over SSH
   deploy/deploy.sh restart             # after a new image is published
   ```
   Logs are in the TrueNAS UI: Apps > agent-runner > Logs. `worker/compose.yaml` is the same
   container for a machine where docker works (`docker compose up -d --build`).
6. **Repo variables (only for the Actions trigger)** (Settings > Secrets and variables > Actions > Variables) in each repo:
   `ANTHROPIC_AGENT_ID`, `ANTHROPIC_ENVIRONMENT_ID`, and optionally `AGENT_BUDGET_USD`
   (default 10, a hard cap per session).
7. **Create the `agent` label** in the repo, then add it to a small issue to test.

For another repo, copy the two GitHub files, add the repo to the PAT, and set the variables. The
federation rule already matches every `derekhearst/*` repo.

## Dev box (SSH + GPU)

The same app runs a `devbox` container from the worker image, for interactive work (SSH, Claude
Remote Control) on the NAS instead of the PC. The issue agent's sandbox worker runs in it too, so
everything shares one memory cap and one work folder. The worker's environment key and GitHub
token reach only the worker process: SSH and Remote Control shells don't inherit them, though the
same user could read the worker process's environment.

- **SSH:** an unprivileged `sshd` on port 2222 (`DEVBOX_SSH_PORT`), key login only, as the `agent`
  user. There is no root and no sudo in the container, so extra system packages are added to
  `worker/Dockerfile` and shipped by the image build. The authorized keys are public keys: the
  `deploy.sh` run reads `~/.ssh/truenas_ed25519.pub` (override with `DEVBOX_PUBKEY_FILES`) and
  rewrites them on every start. Connect with `ssh -p 2222 -i ~/.ssh/truenas_ed25519 agent@192.168.0.2`.
- **Persistent home:** `/mnt/Apps/Apps/AgentRunner/devhome` is mounted as `/home/agent`, so the Claude
  login, `gh` login, git config, shell history and `~/work` survive redeploys. Claude Code and bun are
  installed into it on first start (see `~/.sshd/tools-install.log`) and update themselves.
- **GPU:** the container asks the NVIDIA runtime for the NAS's GPU with compute, video and graphics
  capabilities. The card is shared with the other apps that use it (lifelog, Plex), so the 6 GB of
  video memory is split between them. CUDA and video encode work as is. Vulkan needs two things the
  runtime does not provide: the image carries `libegl1` (the NVIDIA driver refuses to start without
  it) and the entrypoint writes the driver's manifest into `~/.local/share/vulkan/icd.d`. Check
  with `vulkaninfo --summary`: the RTX 2060 should be listed next to the software renderer.
- **GPU rendering for Godot:** the entrypoint starts `Xvfb :99` and sets `DISPLAY=:99` for every
  shell and the Remote Control session, so `tools/shot.sh` and tests render on the RTX 2060
  rather than software Vulkan (RigForSilent's docs/SETUP.md, the box section).
- **Slots:** `rfs-slot COMMAND...` (worker/rfs-slot.sh) shares memory between RigForSilent runs:
  tokens of about 9 GB (`RFS_SLOT_GB`; 3 at 48 GB) that fill the container cap after 10 GB for Claude sessions and agents
  (`RFS_RESERVE_GB`) and the render slot, at most 4 (`RFS_SLOTS` overrides). Renders (`tools/shot.sh`, or `tools/godot.sh`
  opening a scene without `--headless`, `--import` or `--test`) also get their own token of 4 GB (`RFS_RENDER_SLOTS`,
  `RFS_RENDER_GB`; `RFS_RENDER=1|0` overrides the check), so shots on the GPU don't queue behind imports. A whole test suite takes every free token and runs that
  many shards (`landing` one fewer, for its lint); anything else takes one. A run waits only for
  its first token. `~/.claude/CLAUDE.md` (rewritten on every start) gives Claude sessions on the
  box these rules.
- **Lanes:** `rfs-lane new|done|prune|list` (worker/rfs-lane.sh) keeps one worktree per lane at
  `~/work/rfs-LANE`, seeded with copy-on-write clones of the main checkout's Godot cache and LFS
  files, and removes it once it is clean, pushed and in main (never before).
- **The issue agent** works in `~/work` too: RigForSilent checkouts with `rfs-lane new issue-N`,
  heavy runs through the same `rfs-slot` slots. Its git and gh config are in `~/.agent-worker`, so
  your own git identity and gh login are untouched; its log is `~/.sshd/worker.log`. The dev box
  prunes landed lanes hourly (`~/.sshd/lane-prune.log`).
- **Memory:** `DEVBOX_MEM_LIMIT` (default 48g, the box's whole budget: a cap and not a reservation). Godot downloaded by `tools/bootstrap.sh` goes to `/opt/rfs`,
  shared with the worker.

One-time steps after the first deploy: SSH in, run `claude auth login` (it must be the full login,
not `claude setup-token`) and `gh auth login`.

- **Remote Control:** once Claude is logged in, the entrypoint keeps `claude remote-control` running
  in a detached tmux session named `rc` (started in `~/work`, or `DEVBOX_RC_DIR`), and starts it
  again if it exits or the container restarts, so Claude project threads can run on the box. The
  first time, `tmux attach -t rc` to answer the folder trust prompt (detach with Ctrl-b d). Log in
  `~/.sshd/remote-control.log`; `DEVBOX_REMOTE_CONTROL=0` turns it off.

## Cost and safety

- Each session has a hard dollar cap (`AGENT_BUDGET_USD`). At the cap it pauses; it is not
  silently overspent. List cost is tokens plus about $0.08 per session-hour.
- Only people with triage access can add a label, so only they can start the agent. Issue text is
  treated as data by the agent, never as instructions.
- The dev box container (and so the worker) has no root, no Linux capabilities and no Docker socket.
  The agent's blast radius is the GitHub token (scoped repos only), the dev box's files and its
  network access. Egress is not
  restricted by default; tighten it in the TrueNAS firewall if you want.
- The agent never merges and never pushes to the default branch; you review every PR.
- Web search and fetch are off for the agent.

## Tests

`cd worker && AGENT_ID=a ENVIRONMENT_ID=e python test_dispatch.py` checks the supervision rules.

## Not verified yet

Written from the docs, not yet run end to end:

- `ant beta:worker poll --max-idle` (default 1m) stops the work for a *session* that has been idle
  after finishing a turn; it should not end the worker, but watch the first logs to confirm.
- RigForSilent's first session will download Godot 4.7.2 into the `rfs-tools` volume via
  `tools/bootstrap.sh` and may need a long first import; the per-command time limits are in that
  repo's `docs/SETUP.md`.
