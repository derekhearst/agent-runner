#!/bin/bash
# Interactive dev box: an unprivileged sshd on 2222 plus Claude Code and bun in a persistent home.
# Runs as the agent user with no capabilities, so sshd only ever logs in as that user. No agent
# secrets reach this container; GPU access comes from the NVIDIA runtime (see the compose file).
set -euo pipefail

: "${SSH_AUTHORIZED_KEYS:?set SSH_AUTHORIZED_KEYS (public keys, separated by ;)}"

export HOME=/home/agent
mkdir -p "$HOME/.ssh" "$HOME/.sshd" "$HOME/work"
chmod 700 "$HOME/.ssh" "$HOME/.sshd"

# The home dir is a volume, so the files useradd copied in at build time are not there on first run.
cp -n /etc/skel/.profile /etc/skel/.bashrc /etc/skel/.bash_logout "$HOME/" 2>/dev/null || true
grep -q 'HOME/.local/bin' "$HOME/.bashrc" 2>/dev/null \
  || echo 'export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"' >> "$HOME/.bashrc"
grep -q 'HOME/.local/bin' "$HOME/.profile" 2>/dev/null \
  || echo 'export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"' >> "$HOME/.profile"

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

exec /usr/sbin/sshd -D -e -f "$HOME/.sshd/sshd_config"
