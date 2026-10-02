#!/bin/sh
# Launch pi in its hardened container - host-uid variant (plain-Linux Docker).
#
# Runs as your host uid/gid so files the agent creates in the bind-mounted
# workspace are owned by you. The tmpfs over /home/node is chowned to the
# same uid - without that, pi dies at startup with
#   EACCES: permission denied, mkdir '/home/node/.pi/agent/sessions/...'
# (a tmpfs mounts root:root 755 unless uid/gid/mode are set explicitly).
#
# The workspace mounted into the container is your CURRENT directory, so you
# can e.g.:  cd ~/code/myproject && /path/to/pi-hostuid.sh
# The image and ./pi.env (OPENROUTER_API_KEY etc.) are found next to this
# script.
#
# Persistent pi state (config, skills, sessions - everything in ~/.pi) is
# bind-mounted from ./pi-data next to this script, so you can edit it from
# the host or from inside a running container. It inherits your host uid,
# matching the container user.
#
# Usage: pi-hostuid.sh [extra docker args...]   --rebuild forces a rebuild

set -eu

# Resolve symlinks so the script finds pi.env/pi-data/image next to the
# real script, not in whatever directory the symlink lives in.
self=$0
while [ -L "$self" ]; do
  target=$(readlink "$self")
  case $target in
    /*) self=$target ;;                         # absolute symlink
    *) self=$(dirname "$self")/$target ;;        # relative symlink
  esac
done
script_dir=$(cd "$(dirname "$self")" && pwd)
workspace=$(pwd)
data_dir=$script_dir/pi-data
mkdir -p "$data_dir"

image=pi-agent

[ -f "$script_dir/pi.env" ] || {
  echo "error: $script_dir/pi.env not found (create it: OPENROUTER_API_KEY=...)" >&2
  exit 1
}

if [ "${1:-}" = "--rebuild" ]; then
  shift
  docker build -t "$image" "$script_dir"
else
  docker image inspect "$image" >/dev/null 2>&1 || docker build -t "$image" "$script_dir"
fi

exec docker run --rm -it \
  --user "$(id -u):$(id -g)" \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --init \
  --read-only \
  --tmpfs /tmp:rw,size=64m,exec \
  --tmpfs /home/node:rw,size=64m,uid="$(id -u)",gid="$(id -g)",mode=0700 \
  -v "$workspace:/workspace" \
  -v "$data_dir:/home/node/.pi" \
  --env-file "$script_dir/pi.env" \
  "$@" \
  "$image"
