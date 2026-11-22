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
ARG PI_VERSION=1.6.0

# Pin direnv (workspace env loader); apt's bookworm package (2.32) predates
# support for plain .env files, so take the upstream static binary instead.
#   docker build --build-arg DIRENV_VERSION=v2.38.2 .
ARG DIRENV_VERSION=v2.38.2
ARG DIRENV_SHA256=148820a187930d36ca6a204504e5cdb30d8396cd1a97e64c3b3f10d793c11247

# Avoid interactive prompts during apt-get.
ARG DEBIAN_FRONTEND=noninteractive
# Prevent npm from writing update-notifier cache files at runtime.
ENV NPM_CONFIG_UPDATE_NOTIFIER=false
ENV PI_OFFLINE=true
ENV PI_SKIP_VERSION_CHECK=true
ENV PI_TELEMETRY=false

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates curl git ripgrep \
    && rm -rf /var/lib/apt/lists/* \
    # Nothing inside this container ever needs to change uid/gid, so strip
    # all setuid/setgid bits. Removes su, mount, umount, passwd, chsh, ...
    && find / -xdev -perm /6000 -type f -exec chmod a-s {} + \
    # Fail the build if anything somehow kept its privileged bits.
    && ! find / -xdev -perm /6000 -type f | grep -q .

# Pin the DuckDB CLI so the agent can run local analytical SQL directly
# against parquet/csv/json/sqlite files in the workspace (no database server).
#   docker build --build-arg DUCKDB_VERSION=v2.0.1 .
ARG DUCKDB_VERSION=v2.0.1

# direnv lets a workspace carry its own environment: a .envrc or plain .env
# at the project root is loaded into the agent's environment at container
# start (see pi-entrypoint.sh). --checksum pins the binary so the URL fetch
# can't silently change under us.
ADD --checksum=sha256:${DIRENV_SHA256} \
    https://github.com/direnv/direnv/releases/download/${DIRENV_VERSION}/direnv.linux-amd64 \
    /usr/local/bin/direnv
RUN chmod 0755 /usr/local/bin/direnv

# DuckDB CLI so the agent can run local analytical SQL directly against
# parquet/csv/json/sqlite files in the workspace (no database server).
# Unlike direnv (a static binary), the duckdb CLI is glibc-linked and
# arch-specific, so pick the tarball matching the build platform and verify
# its checksum. TARGETARCH is the automatic build arg from --platform.
ARG TARGETARCH
RUN set -eu \
    && case "${TARGETARCH}" in \
         amd64) DUCKDB_SHA256=b676268be4d39e4e41a904442c9796c9914e645cc085c7505f048f2c992b5eca ;; \
         arm64) DUCKDB_SHA256=84e37891fcc45c887e30220f51a4914995cd8174139e87f8efd311ac83c956a7 ;; \
         *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
       esac \
    && curl -fsSL -o /tmp/duckdb.tar.gz \
         https://github.com/duckdb/duckdb/releases/download/${DUCKDB_VERSION}/duckdb-cli-linux-${TARGETARCH}.tar.gz \
    && echo "${DUCKDB_SHA256}  /tmp/duckdb.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/duckdb.tar.gz -C /usr/local/bin \
    && chmod 0755 /usr/local/bin/duckdb \
    && rm /tmp/duckdb.tar.gz

# direnv ignores plain .env files unless load_dotenv is enabled. Bake the
# config root-owned outside $HOME - the runtime mounts a tmpfs over
# /home/node, so anything under it in the image would be hidden.
# Empty DIRENV_LOG_FORMAT silences the 'direnv: loading ...' status line
# before pi starts (errors still print).
ENV DIRENV_CONFIG=/etc/direnv
ENV DIRENV_LOG_FORMAT=
RUN mkdir -p /etc/direnv \
    && printf 'load_dotenv = true\n' > /etc/direnv/direnv.toml

# Install pi globally as root. --ignore-scripts is essential hardening.
# --cache keeps npm's cache out of /root (and therefore out of a layer).
RUN npm install -g --ignore-scripts --no-audit --no-fund --cache /tmp/npm-cache \
      @earendil-works/pi-coding-agent@${PI_VERSION} \
    && rm -rf /tmp/npm-cache

# pi stores sessions and config in $HOME/.pi, so it needs a writable home.
# Set HOME explicitly (the early root layers default it to /root).
ENV HOME=/home/node

# Entrypoint wrapper: applies the workspace's .envrc/.env via direnv before
# handing off to pi. Installed root-owned before the privilege drop.
COPY --chmod=755 pi-entrypoint.sh /usr/local/bin/pi-entrypoint

RUN mkdir -p /workspace \
    && chown -R node:node /home/node /workspace

# Drop root for good. Numeric form so Kubernetes runAsNonRoot checks pass
# (uid 1000 is the `node` user in this image's /etc/passwd).
USER 1000:1000
WORKDIR /workspace

ENTRYPOINT ["pi-entrypoint"]

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
#     --tmpfs /home/node:rw,size=256m,uid=1000,gid=1000,mode=0700 \  # $HOME/.pi + duckdb extensions
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
#     --tmpfs /home/node:rw,size=256m,uid="$(id -u)",gid="$(id -g)",mode=0700 \
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
#   * Per-project env via direnv: a .envrc (direnv syntax) or plain .env
#     (KEY=VALUE lines) at the workspace root is auto-loaded into the
#     session at startup - no --env-file needed for project-specific vars.
#     The launch scripts' ./pi.env (--env-file) still applies on top; use
#     it for provider keys you don't want to keep in the workspace.
#     NOTE: .envrc/.env content is evaluated as shell code at container
#     start - only do this in workspaces you trust, and never commit secrets.
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
