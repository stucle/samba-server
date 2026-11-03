#!/bin/sh
# Wrapper script: runs docker compose with config.env as the interpolation file, e.g. ./smb.sh up -d --build, so callers never have to pass --env-file.
#
# It also picks the log mount overlay, since compose itself cannot branch between mount types at runtime. There are 3 scenarios:
#   1. SMB_LOG_HOST_PATH is empty or not creatable/writable -> use the "samba_log" volume.
#   2. SMB_LOG_HOST_PATH is usable -> bind mount logs there.
#   3. The "up" command with the bind mount fails -> retry once with the "samba_log" volume.
#
# It also appends --build to "up" so the baked-in entrypoint.sh stays current.
#
# Besides the compose subcommands it adds one of its own:
#   ./smb.sh state export <dir> | import <dir> | show
# to copy the runtime state (dynamic.conf, accounts.tsv) in and out of the samba_core volume, which is not reachable from the host filesystem.
cd "$(dirname "$0")" || exit 1

conf_value() { sed -n "s/^$1=//p" config.env | tail -n 1; }

# "state" is not a compose subcommand: the runtime state lives in the samba_core named volume, which the host cannot read directly,
# so copying goes through `docker cp` against the running container.
if [ "$1" = state ]; then
  container=$(conf_value SMB_CONTAINER_NAME)
  state_dir=$(conf_value SMB_STATE_DIR)
  if [ -z "$container" ] || [ -z "$state_dir" ]; then
    echo "[smb.sh] SMB_CONTAINER_NAME or SMB_STATE_DIR is missing from config.env" >&2
    exit 1
  fi
  case "$2" in
    export)
      [ -n "$3" ] || { echo "usage: $0 state export <dir>" >&2; exit 1; }
      mkdir -p "$3" || exit 1
      exec docker cp "$container:$state_dir/." "$3"
      ;;
    import)
      [ -d "$3" ] || { echo "usage: $0 state import <dir>   (<dir> must exist)" >&2; exit 1; }
      # docker cp into a RUNNING container writes straight through to the volume;
      # Samba still has to be told to re-read the included file.
      docker cp "$3/." "$container:$state_dir" || exit 1
      exec docker exec "$container" smbcontrol all reload-config
      ;;
    show)
      exec docker exec "$container" smbctl state-dump
      ;;
    *)
      echo "usage: $0 state {export <dir>|import <dir>|show}" >&2
      echo "  seed before the container exists:" >&2
      echo "    docker run --rm -v samba_core:/state -v \"\$PWD/seed\":/seed:ro alpine cp -a /seed/. /state/" >&2
      exit 1
      ;;
  esac
fi

# entrypoint.sh is baked into the image by the Dockerfile,
# so "up" always builds: without --build, compose reuses a stale image and edits to entrypoint.sh are silently ignored.
#The build is layer-cached, so it is a no-op when unchanged.
if [ "$1" = up ]; then
  case " $* " in
    *" --build "*|*" --no-build "*) ;;
    *) set -- "$@" --build ;;
  esac
fi

log_host_path=$(conf_value SMB_LOG_HOST_PATH)
log_overlay=compose.log-volume.yaml

if [ -n "$log_host_path" ] && mkdir -p "$log_host_path" 2>/dev/null && [ -w "$log_host_path" ]; then
  log_overlay=compose.log-bind.yaml
fi

if [ "$log_overlay" = compose.log-bind.yaml ] && [ "$1" = up ]; then
  if docker compose --env-file config.env -f compose.yaml -f compose.log-bind.yaml "$@"; then
    exit 0
  fi
  echo "[smb.sh] log bind mount ($log_host_path) failed, falling back to volume samba_log" >&2
  log_overlay=compose.log-volume.yaml
fi

exec docker compose --env-file config.env -f compose.yaml -f "$log_overlay" "$@"
