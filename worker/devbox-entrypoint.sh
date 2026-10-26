#!/bin/bash
# Interactive dev box: an unprivileged sshd on 2222 plus Claude Code and bun in a persistent home.
# Runs as the agent user with no capabilities, so sshd only ever logs in as that user. No agent
# secrets reach this container; GPU access comes from the NVIDIA runtime (see the compose file).
set -euo pipefail

: "${SSH_AUTHORIZED_KEYS:?set SSH_AUTHORIZED_KEYS (public keys, separated by ;)}"

export HOME=/home/agent

# The issue agent's worker settings. Kept in plain variables for the worker alone and taken out
# of the environment, so sshd, Remote Control and their shells never inherit them.
w_key="${ANTHROPIC_ENVIRONMENT_KEY:-}" w_env="${ANTHROPIC_ENVIRONMENT_ID:-}" w_gh="${GH_TOKEN:-}"
w_name="${GIT_NAME:-Claude Agent}" w_email="${GIT_EMAIL:-noreply@anthropic.com}"
unset ANTHROPIC_ENVIRONMENT_KEY ANTHROPIC_ENVIRONMENT_ID GH_TOKEN GIT_NAME GIT_EMAIL
mkdir -p "$HOME/.ssh" "$HOME/.sshd" "$HOME/work"
chmod 700 "$HOME/.ssh" "$HOME/.sshd"

# The home dir is a volume, so the files useradd copied in at build time are not there on first run.
cp -n /etc/skel/.profile /etc/skel/.bashrc /etc/skel/.bash_logout "$HOME/" 2>/dev/null || true
grep -q 'HOME/.local/bin' "$HOME/.bashrc" 2>/dev/null \
  || echo 'export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"' >> "$HOME/.bashrc"
grep -q 'HOME/.local/bin' "$HOME/.profile" 2>/dev/null \
  || echo 'export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"' >> "$HOME/.profile"

# A virtual display for Godot: with DISPLAY set, shots and tests render on the GPU (NVIDIA's
# Vulkan driver) instead of software Vulkan. The socket is in the container's /tmp, so it is
# started fresh on every boot.
export DISPLAY=:99
grep -q 'DISPLAY=:99' "$HOME/.profile" 2>/dev/null || echo 'export DISPLAY=:99' >> "$HOME/.profile"
grep -q 'DISPLAY=:99' "$HOME/.bashrc" 2>/dev/null || echo 'export DISPLAY=:99' >> "$HOME/.bashrc"
[ -e /tmp/.X11-unix/X99 ] || setsid Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp \
  > "$HOME/.sshd/xvfb.log" 2>&1 < /dev/null &

# Box rules for Claude sessions here. Rewritten on every start from this image, so change them
# in agent-runner; a session's own notes go in ~/.claude/rules/ or the project's memory.
mkdir -p "$HOME/.claude"
cat > "$HOME/.claude/CLAUDE.md" <<'RULES'
# The TrueNAS dev box

(Written by agent-runner's devbox-entrypoint.sh on every start; edits here are lost.)

## Memory: the box's whole budget is the container cap (40 GB)

- Run every heavy RigForSilent command through `rfs-slot`: `rfs-slot tools/test.sh lobby`,
  `rfs-slot tools/shot.sh ...`, `rfs-slot tools/godot.sh --import`, `rfs-slot tools/bpy.sh ...`.
  It sizes its slots (about 9 GB each, so 3 at 40 GB) from the cap, keeping 10 GB for Claude sessions, agents
  and shells, and sets the shard count. It waits for a free slot, so never retry it in a loop.
- Never raise RFS_SLOTS, RFS_TEST_SHARDS or the memory guard to go faster.
- At most 3 subagents or workflow agents at once on the box; their heavy runs go through
  `rfs-slot` like yours.
- Start long runs with the Bash tool's run_in_background, never `cmd &`.

## Worktrees: one per lane, removed once landed
- The main checkout is ~/work/RigForSilent. Make a lane with `rfs-lane new LANE` (worktree
  ~/work/rfs-LANE on claude/rfs-LANE; the Godot cache and LFS files are copy-on-write clones,
  so it costs a few GB instead of ~20). Never `git worktree add` by hand.
- When a lane's PR lands, `rfs-lane done LANE` right away. At the start and end of each session,
  `rfs-lane prune` (removes every landed lane that is clean and pushed) and `rfs-lane list`.
- Never delete a worktree with uncommitted or unpushed work; `rfs-lane` refuses to.
- New lanes clone the import cache of ~/work/.rfs-seed (origin/main, imported). After a landing,
  run `rfs-lane seed` (the box also does it hourly when main moves, and prunes landed lanes;
  log ~/.sshd/lane-prune.log). Never edit or build in ~/work/.rfs-seed.
- The `agent`-label issue worker shares ~/work and the slots: its lanes are ~/work/rfs-issue-N.
  Leave those to it unless they have landed.

## GPU
- `DISPLAY=:99` (Xvfb) is set, so Godot renders on the RTX 2060. The card is shared with
  Plex and lifelog (6 GB VRAM). `--software` forces lavapipe if a shot comes out black.
RULES

# Keys come from the app config on every start, so removing one there revokes it.
printf '%s\n' "$SSH_AUTHORIZED_KEYS" | tr ';' '\n' | sed '/^[[:space:]]*$/d' > "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"

# Host key lives in the volume so clients do not see a changed key after a redeploy.
[ -f "$HOME/.sshd/ssh_host_ed25519_key" ] \
  || ssh-keygen -q -t ed25519 -N '' -f "$HOME/.sshd/ssh_host_ed25519_key"

cat > "$HOME/.sshd/sshd_config" <<CFG
Port 2222
HostKey $HOME/.sshd/ssh_host_ed25519_key
PidFile $HOME/.sshd/sshd.pid
AuthorizedKeysFile $HOME/.ssh/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
StrictModes no
PermitRootLogin no
X11Forwarding no
AllowUsers agent
PrintMotd no
ClientAliveInterval 60
ClientAliveCountMax 5
Subsystem sftp /usr/lib/openssh/sftp-server
CFG

# The NVIDIA runtime injects the driver libraries but not the Vulkan manifest, so without this
# Vulkan only sees the software renderer. The driver also needs libEGL (libegl1, installed in the image).
if [ -e /dev/nvidia0 ]; then
  mkdir -p "$HOME/.local/share/vulkan/icd.d"
  cat > "$HOME/.local/share/vulkan/icd.d/nvidia_icd.json" <<'ICD'
{"file_format_version":"1.0.0","ICD":{"library_path":"libGLX_nvidia.so.0","api_version":"1.3.289"}}
ICD
fi

# Claude Code and bun install into the home volume the first time and update themselves after.
# Done in the background so sshd is up straight away; a failed download is retried on the next start.
(
  export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"
  command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash \
    || echo "claude install failed, will retry on the next start"
  command -v bun >/dev/null || curl -fsSL https://bun.sh/install | bash \
    || echo "bun install failed, will retry on the next start"
) > "$HOME/.sshd/tools-install.log" 2>&1 &

# Claude Code Remote Control in a detached tmux session named "rc", so project threads can run
# here without anyone keeping an SSH session open. It waits for the one-time `claude auth login`
# (the credentials file in the home volume) and is restarted if it exits.
# Watch it with `tmux attach -t rc` (detach: Ctrl-b d); the first run may ask to trust the folder.
# DEVBOX_REMOTE_CONTROL=0 turns it off; DEVBOX_RC_DIR is the folder it starts in.
if [ "${DEVBOX_REMOTE_CONTROL:-1}" != "0" ]; then
  (
    export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"
    rc_dir="${DEVBOX_RC_DIR:-$HOME/work}"
    until command -v claude >/dev/null && [ -s "$HOME/.claude/.credentials.json" ]; do sleep 30; done
    while true; do
      tmux has-session -t rc 2>/dev/null \
        || tmux new-session -d -s rc -c "$rc_dir" "claude remote-control; sleep 30"
      sleep 60
    done
  ) > "$HOME/.sshd/remote-control.log" 2>&1 &
fi

# The issue agent's sandbox worker (entrypoint.sh), restarted if it exits. Its git and gh config
# live in ~/.agent-worker, so Derek's own git identity and gh login are left alone.
if [ -n "$w_key" ] && [ -n "$w_env" ] && [ -n "$w_gh" ]; then
  (
    mkdir -p "$HOME/.agent-worker/gh"
    while true; do
      env ANTHROPIC_ENVIRONMENT_KEY="$w_key" ANTHROPIC_ENVIRONMENT_ID="$w_env" GH_TOKEN="$w_gh" \
        GIT_NAME="$w_name" GIT_EMAIL="$w_email" \
        GIT_CONFIG_GLOBAL="$HOME/.agent-worker/gitconfig" GH_CONFIG_DIR="$HOME/.agent-worker/gh" \
        /usr/local/bin/entrypoint.sh || echo "worker exited ($?), restarting in 30 s"
      sleep 30
    done
  ) > "$HOME/.sshd/worker.log" 2>&1 &
else
  echo "no worker settings; the issue agent's worker is not started" > "$HOME/.sshd/worker.log"
fi

# Every hour: re-import the lane seed if main has moved, so new lanes start warm, and remove
# landed lanes (the dev box's and the issue agent's) even when the session that made them never
# came back. rfs-lane keeps anything uncommitted or unpushed.
(
  while true; do
    sleep 3600
    if [ -d "$HOME/work/RigForSilent/.git" ]; then
      rfs-lane seed --if-stale || true
      rfs-lane prune || true
    fi
  done
) > "$HOME/.sshd/lane-prune.log" 2>&1 &

exec /usr/sbin/sshd -D -e -f "$HOME/.sshd/sshd_config"
