#!/bin/bash
# Prepares git/gh for the agent, then runs the worker. Secrets stay in the environment.
set -euo pipefail

: "${ANTHROPIC_ENVIRONMENT_KEY:?set ANTHROPIC_ENVIRONMENT_KEY (Console > Environments > Generate environment key)}"
: "${ANTHROPIC_ENVIRONMENT_ID:?set ANTHROPIC_ENVIRONMENT_ID (env_...)}"
: "${GH_TOKEN:?set GH_TOKEN (fine-grained PAT limited to the repos the agent may work on)}"

git config --global user.name "${GIT_NAME:-Claude Agent}"
git config --global user.email "${GIT_EMAIL:-noreply@anthropic.com}"
gh auth setup-git

exec ant beta:worker poll \
  --environment-id "$ANTHROPIC_ENVIRONMENT_ID" \
  --workdir /workspace
