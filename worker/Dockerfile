# Self-hosted sandbox worker for Claude Managed Agents, and the base of the SSH dev box.
# Polls Anthropic's work queue (outbound only) and runs the agent's bash and file tools here.
# Includes what the RigForSilent toolchain needs on Linux (docs/SETUP.md): Python 3, Git LFS,
# xvfb and software Vulkan. Godot itself is downloaded by tools/bootstrap.sh into /opt/rfs, a volume.
FROM ubuntu:24.04

ARG ANT_VERSION=1.40.0
ARG AGENT_UID=950

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git git-lfs gnupg jq unzip \
      python3 python3-pip python3-venv \
      xvfb mesa-vulkan-drivers espeak-ng sox libcairo2 \
      openssh-server tmux less nano procps rsync build-essential vulkan-tools \
      libegl1 libgl1 libgles2 libopengl0 \
    && rm -f /etc/ssh/ssh_host_* \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
         -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
         > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# The Anthropic CLI; `ant beta:worker poll` is the worker.
RUN curl -fsSL "https://github.com/anthropics/anthropic-cli/releases/download/v${ANT_VERSION}/ant_${ANT_VERSION}_linux_amd64.tar.gz" \
      | tar -xz -C /usr/local/bin ant \
    && ant --version

# The dispatcher (dispatch.py) runs in its own container from this same image.
RUN python3 -m venv /opt/venv && /opt/venv/bin/pip install --no-cache-dir anthropic==1.13.0
COPY --chmod=0755 dispatch.py /opt/dispatch.py

RUN git lfs install --system \
    && useradd --uid "${AGENT_UID}" --create-home --shell /bin/bash agent \
    && mkdir -p /workspace /opt/rfs \
    && chown agent:agent /workspace /opt/rfs

COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh
# The devbox container (SSH + GPU) runs this image with this entrypoint instead.
COPY --chmod=0755 devbox-entrypoint.sh /usr/local/bin/devbox-entrypoint.sh
# Shares the dev box's memory between RigForSilent runs (see the script).
COPY --chmod=0755 rfs-slot.sh /usr/local/bin/rfs-slot

USER agent
WORKDIR /workspace
ENV RFS_TOOLS=/opt/rfs
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
