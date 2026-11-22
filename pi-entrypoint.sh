#!/bin/sh
# Container entrypoint: load workspace env via direnv, then exec pi.
#
# direnv support: if the mounted workspace root (/workspace) contains a
# .envrc or a plain .env file, its variables are exported into the agent's
# environment before pi starts. This replaces the --env-file ./pi.env
# approach for anything project-specific - the environment now travels
# with the workspace, not with the launcher script.
#
#   .envrc  - full direnv syntax (exports, stdlib helpers, shell logic)
#   .env    - plain KEY=VALUE lines, loaded direnv-style
#
# The file is auto-`direnv allow`ed on start so no interactive approval is
# needed. Be aware this is the same trust decision as running `direnv allow`
# yourself: .envrc (and .env) content is evaluated as shell code at container
# startup, so only do this in workspaces you trust.

set -eu

rc=/workspace/.envrc
[ -f "$rc" ] || rc=/workspace/.env

if [ -f "$rc" ]; then
    # Record the file's hash so direnv loads it without prompting.
    direnv allow "$rc"
    exec direnv exec /workspace pi "$@"
fi

exec pi "$@"
