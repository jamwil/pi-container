# syntax=docker/dockerfile:1
#
# Hardened pi coding-agent container.
#
# Build-time hardening:
#   1. Runs as the unprivileged `node` user (uid/gid 1000) from the base
#      image - nothing at runtime ever executes as root.
#   2. All setuid/setgid binaries are stripped (su, mount, passwd, chsh, ...),
#      removing the local privilege-escalation surface inside the container.
#   3. pi is installed with --ignore-scripts, so no npm lifecycle scripts
#      (arbitrary code) can execute as root during the build.
#   4. pi is pinned to an exact version for reproducible builds.
#   5. /workspace is pre-created and owned by the runtime user; npm cache
#      is kept out of the image layers.
#
# Pair this with the hardened runtime invocation documented at the bottom.

FROM node:24-bookworm-slim

# Pin the agent version; update deliberately via:
#   docker build --build-arg PI_VERSION=1.1.0 .
ARG PI_VERSION=1.3.0

# Avoid interactive prompts during apt-get.
ARG DEBIAN_FRONTEND=noninteractive
# Prevent npm from writing update-notifier cache files at runtime.
ENV NPM_CONFIG_UPDATE_NOTIFIER=false
ENV PI_OFFLINE=true
ENV PI_SKIP_VERSION_CHECK=true
ENV PI_TELEMETRY=false

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates git ripgrep \
    && rm -rf /var/lib/apt/lists/* \
    # Nothing inside this container ever needs to change uid/gid, so strip
    # all setuid/setgid bits. Removes su, mount, umount, passwd, chsh, ...
    && find / -xdev -perm /6000 -type f -exec chmod a-s {} + \
    # Fail the build if anything somehow kept its privileged bits.
    && ! find / -xdev -perm /6000 -type f | grep -q .

# Install pi globally as root. --ignore-scripts is essential hardening.
# --cache keeps npm's cache out of /root (and therefore out of a layer).
RUN npm install -g --ignore-scripts --no-audit --no-fund --cache /tmp/npm-cache \
      @earendil-works/pi-coding-agent@${PI_VERSION} \
    && rm -rf /tmp/npm-cache

# pi stores sessions and config in $HOME/.pi, so it needs a writable home.
# Set HOME explicitly (the early root layers default it to /root).
ENV HOME=/home/node

RUN mkdir -p /workspace \
    && chown -R node:node /home/node /workspace

# Drop root for good. Numeric form so Kubernetes runAsNonRoot checks pass
# (uid 1000 is the `node` user in this image's /etc/passwd).
USER 1000:1000
WORKDIR /workspace

ENTRYPOINT ["pi"]

# -----------------------------------------------------------------------------
# Recommended hardened invocation (image default user, uid 1000):
#
#   docker build -t pi-agent .
#
#   docker run --rm -it \
#     --cap-drop=ALL \                    # the agent needs no capabilities at all
#     --security-opt=no-new-privileges \  # never allow privilege escalation
#     --init \                            # proper PID 1 / signal handling
#     --read-only \                       # immutable root filesystem
#     --tmpfs /tmp:rw,size=64m,exec \      # scratch space (node compile cache, ...)
#     --tmpfs /home/node:rw,size=64m,uid=1000,gid=1000,mode=0700 \  # $HOME/.pi
#     -v "$PWD:/workspace" \              # your project; the only persistent rw mount
#     --env-file ./pi.env \                # OPENROUTER_API_KEY etc. (never bake secrets in)
#     pi-agent
#
# If you instead override the user to match your host uid (needed for bind
# mounts on a plain-Linux Docker host), the tmpfs MUST be chowned to that
# same uid, or pi dies at startup with:
#     Error: EACCES: permission denied,
#     mkdir '/home/node/.pi/agent/sessions/--workspace--'
# A tmpfs mounts as root:root mode 755 unless uid/gid/mode are set explicitly
# (and Node reports the deepest path of a recursive mkdir even though the
# real failure is the first component, /home/node/.pi):
#
#   docker run --rm -it \
#     --user "$(id -u):$(id -g)" \
#     --cap-drop=ALL --security-opt=no-new-privileges --init --read-only \
#     --tmpfs /tmp:rw,size=64m,exec \
#     --tmpfs /home/node:rw,size=64m,uid="$(id -u)",gid="$(id -g)",mode=0700 \
#     -v "$PWD:/workspace" --env-file ./pi.env pi-agent
#
# Notes:
#   * --user overrides the image's USER (uid 1000). Matching your host
#     uid/gid keeps files the agent creates in the bind-mounted /workspace
#     owned by you on a plain-Linux Docker host. On Docker Desktop
#     (macOS/Windows) you can omit --user entirely - the file-sharing layer
#     maps ownership for you, so the uid=1000 invocation above is fine.
#     If you run Docker itself as root (host uid 0), keep the image default
#     (1000) instead and chown your workspace on the host.
#   * The tmpfs on /home/node makes agent state ephemeral. To persist pi's
#     config/skills/sessions, either mount a named volume over /home/node
#     (a named volume inherits /home/node's image ownership on first use, so
#     the uid=1000 default works there too), or bind-mount a host directory
#     at /home/node/.pi as the launch scripts in this directory do - that
#     keeps it editable from the host as well as inside the container.
#   * The agent needs outbound HTTPS to your model provider, so --network
#     none is not an option; restrict egress at the network/firewall level
#     instead (e.g. allowlist the provider's API endpoints).
#   * For even stricter reproducibility, pin the base image by digest:
#       docker manifest inspect node:24-bookworm-slim
#       FROM node:24-bookworm-slim@sha256:<digest>
# -----------------------------------------------------------------------------
