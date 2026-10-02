#!/bin/sh
# Launch pi in its hardened container - Docker Desktop variant (macOS/Windows).
#
# Runs as the image's default user (uid 1000). Docker Desktop's file-sharing
# layer maps bind-mount ownership for you, so the workspace mount just works
# without matching your host uid.
#
# The workspace mounted into the container is your CURRENT directory, so you
# can e.g.:  cd ~/code/myproject && /path/to/pi-desktop.sh
# The image and ./pi.env (OPENROUTER_API_KEY etc.) are found next to this
# script.
#
# Persistent pi state (config, skills, sessions - everything in ~/.pi) is
# bind-mounted from ./pi-data next to this script, so you can edit it from
# the host or from inside a running container.
#
# Usage: pi-desktop.sh [extra docker args...]   --rebuild forces a rebuild

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
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --init \
  --read-only \
  --tmpfs /tmp:rw,size=64m,exec \
  --tmpfs /home/node:rw,size=64m,uid=1000,gid=1000,mode=0700 \
  -v "$workspace:/workspace" \
  -v "$data_dir:/home/node/.pi" \
  --env-file "$script_dir/pi.env" \
  "$@" \
  "$image"
