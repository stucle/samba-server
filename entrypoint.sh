#!/bin/sh
# Replaces the dockurr/samba entrypoint: renders /etc/samba/smb.conf from config.env and runs smbd.
# The stock entrypoint starts smbd with --debug-stdout, which ignores "log file" and would bypass the samba_log volume.
set -eu

readonly CONF=/etc/samba/smb.conf

log()  { echo "[entrypoint] $*"; }
warn() { echo "[entrypoint] WARNING: $*" >&2; }
die()  { echo "[entrypoint] ERROR: $*" >&2; exit 1; }

require_env() {
  for name in "$@"; do
    eval "value=\${$name:-}"
    [ -n "$value" ] || die "$name is not set in config.env"
  done
}

# Prints the English ordinal of <index>: 1st, 2nd, 3rd, 4th, ..., 11th, 12th, 13th, 21st.
ordinal() {
  case $1 in
    *1[123]) echo "${1}th" ;;
    *1) echo "${1}st" ;;
    *2) echo "${1}nd" ;;
    *3) echo "${1}rd" ;;
    *) echo "${1}th" ;;
  esac
}

# Prints the name of SHARE_<key>_<ordinal>.
share_var_name() {
  echo "SHARE_$2_$(ordinal "$1")"
}

# Prints SHARE_<key>_<ordinal>, or <default> when unset.
share_var() {
  eval "echo \"\${$(share_var_name "$1" "$2"):-$3}\""
}

share_exists() {
  [ -n "$(share_var "$1" NAME '')" ]
}

# Names that reach smb.conf, adduser and addgroup must be this restrictive:
# they are otherwise a config/command injection vector.
valid_name() {
  case $1 in
    '' | -* | *[!a-z0-9_-]*) return 1 ;;
  esac
  [ "${#1}" -le 32 ]
}

# Creates a login-less Unix account; extra args go to adduser (e.g. -u <uid>).
ensure_user() {
  name=$1
  shift
  id "$name" >/dev/null 2>&1 \
    || adduser -D -H -s /sbin/nologin -G "$GROUP_NAME" "$@" "$name"
}

# The writer owns files on the host, so it gets SMB_UID. The reader never writes, so any UID works.
ensure_accounts() {
  [ "$SMB_READ_USER" != "$SMB_WRITE_USER" ] || die "SMB_READ_USER and SMB_WRITE_USER must differ"
  GROUP_NAME=$(getent group "$SMB_GID" | cut -d: -f1 || true)
  if [ -z "$GROUP_NAME" ]; then
    GROUP_NAME="$SMB_WRITE_USER"
    addgroup -g "$SMB_GID" "$GROUP_NAME"
  fi
  ensure_user "$SMB_WRITE_USER" -u "$SMB_UID"
  ensure_user "$SMB_READ_USER"
}

# Replays $SMB_STATE_DIR/accounts.tsv (written by smbctl) into Unix accounts and group membership,
# which live in the container layer and are therefore lost on every recreate. passdb.tdb survives in the samba_private volume,
# so passwords are NOT stored here and never re-set from this file.
#
# Format, tab-separated, "#" comments and blank lines ignored:   <user><TAB><group>[,<group>...]
# An invalid line is a warning, not a fatal error: one bad line must not keep the whole server down.
reconcile_accounts() {
  state_file="$SMB_STATE_DIR/accounts.tsv"
  [ -f "$state_file" ] || return 0
  tab=$(printf '\t')
  reconciled=0

  # The `|| [ -n "$line" ]` tail processes a final line with no trailing newline.
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in '' | \#*) continue ;; esac

    user=${line%%"$tab"*}
    groups=${line#*"$tab"}
    [ "$groups" != "$line" ] || groups=''      # no tab at all -> no groups
    groups=$(echo "$groups" | tr ',' ' ')

    if ! valid_name "$user"; then
      warn "accounts.tsv: invalid user name '$user'; line skipped"
      continue
    fi
    invalid_group=''
    for group in $groups; do
      valid_name "$group" || invalid_group=$group
    done
    if [ -n "$invalid_group" ]; then
      warn "accounts.tsv: invalid group name '$invalid_group' for user '$user'; line skipped"
      continue
    fi

    for group in $groups; do
      getent group "$group" >/dev/null 2>&1 || addgroup "$group"
    done
    ensure_user "$user"
    for group in $groups; do
      id -nG "$user" | tr ' ' '\n' | grep -qx "$group" || adduser "$user" "$group"
    done

    # No UID column by design: every share has `force user = $SMB_WRITE_USER`, so a
    # runtime user's UID never reaches the host filesystem. Let adduser pick one.
    pdbedit -L 2>/dev/null | cut -d: -f1 | grep -qx "$user" \
      || warn "accounts.tsv: user '$user' has no entry in passdb.tdb (state drift); not setting a password"
    reconciled=$((reconciled + 1))
  done < "$state_file"

  [ "$reconciled" -eq 0 ] || log "reconciled $reconciled account(s) from accounts.tsv"
}

# Drops modules that are missing from the image: smbd refuses every share, IPC$ included, if one fails to load.
resolve_vfs_objects() {
  requested="${SMB_VFS_OBJECTS:-}"
  module_dir=$(smbd -b | sed -n 's/^ *MODULESDIR: *//p')
  VFS_OBJECTS=""
  for module in $requested; do
    if [ -f "$module_dir/vfs/$module.so" ]; then
      VFS_OBJECTS="$VFS_OBJECTS $module"
    else
      warn "VFS module '$module' is not available; skipping"
    fi
  done
  VFS_OBJECTS="${VFS_OBJECTS# }"
}

render_global() {
  # smbd-notifyd and smbd-cleanupd count towards "max smbd processes".
  clients=${SMB_CONCURRENT_CONNECTIONS:-0}
  max_processes=0
  [ "$clients" -gt 0 ] && max_processes=$((clients + 2))

  cat <<CONF_EOF
[global]
   workgroup = ${SMB_WORKGROUP:-WORKGROUP}
   server string = ${SMB_SERVER_STRING:-Samba}
   netbios name = ${SMB_NETBIOS_NAME:-SMBSERVER}
   server role = standalone server
   security = user
   map to guest = never
   passdb backend = tdbsam
   smb ports = 445
   disable netbios = yes
   load printers = no
   printing = bsd
   printcap name = /dev/null
   disable spoolss = yes

   server min protocol = ${SMB_SERVER_MIN_PROTOCOL:-SMB2_10}
   server max protocol = ${SMB_SERVER_MAX_PROTOCOL:-SMB3}
   server signing = ${SMB_SERVER_SIGNING:-default}
   server smb encrypt = ${SMB_ENCRYPT:-if_required}

   logging = file
   log file = ${SMB_LOG_DIR}/log.%m
   log level = ${SMB_LOG_LEVEL:-1}
   max log size = ${SMB_MAX_LOG_SIZE:-10240}

   max smbd processes = ${max_processes}
   deadtime = ${SMB_DEADTIME:-0}
   keepalive = ${SMB_KEEPALIVE:-300}

   vfs objects = ${VFS_OBJECTS}
   ea support = ${SMB_EA_SUPPORT:-yes}
   store dos attributes = ${SMB_EA_SUPPORT:-yes}
   fruit:model = MacSamba
   fruit:aapl = yes
   fruit:nfs_aces = no
   fruit:wipe_intentionally_left_blank_rfork = yes
   fruit:delete_empty_adfiles = yes
   fruit:metadata = ${SMB_FRUIT_METADATA:-stream}

CONF_EOF
}

warn_if_not_writable() {
  index=$1 path=$2 user=$3
  [ "$(share_var "$index" READ_ONLY no)" = no ] || return 0
  su -s /bin/sh -c "touch '$path/.smb_write_probe' && rm -f '$path/.smb_write_probe'" "$user" 2>/dev/null \
    || warn "user '$user' cannot write to $path; fix host permissions or set $(share_var_name "$index" FORCE_USER)=root"
}

render_share() {
  index=$1
  name=$(share_var "$index" NAME '')
  path=$(share_var "$index" CONTAINER_PATH '')
  force_user=$(share_var "$index" FORCE_USER "$SMB_WRITE_USER")

  [ -d "$path" ] || die "share '$name': $path does not exist; check $(share_var_name "$index" HOST_PATH)"
  warn_if_not_writable "$index" "$path" "$force_user"

  cat <<SHARE_EOF
[${name}]
   path = ${path}
   comment = $(share_var "$index" COMMENT '')
   read only = $(share_var "$index" READ_ONLY no)
   browseable = $(share_var "$index" BROWSEABLE yes)
   guest ok = $(share_var "$index" GUEST_OK no)
   valid users = $(share_var "$index" VALID_USERS "$SMB_READ_USER $SMB_WRITE_USER")
   read list = $(share_var "$index" READ_LIST "$SMB_READ_USER")
   write list = $(share_var "$index" WRITE_LIST "$SMB_WRITE_USER")
   force user = ${force_user}
   force group = ${GROUP_NAME}
   create mask = $(share_var "$index" CREATE_MASK 0664)
   directory mask = $(share_var "$index" DIRECTORY_MASK 0775)
   max connections = $(share_var "$index" MAX_CONNECTIONS "${SMB_MAX_CONNECTIONS:-0}")
   veto files = $(share_var "$index" VETO_FILES '')
   delete veto files = $(share_var "$index" DELETE_VETO_FILES no)

SHARE_EOF
}

render_config() {
  render_global
  i=1
  while share_exists "$i"; do
    render_share "$i"
    i=$((i + 1))
  done
  SHARE_COUNT=$((i - 1))

  # Runtime-created shares, on the persistent samba_core volume.
  # Must be the LAST line and outside [global]: `include` splices the file in at this point,
  # so a [share] block in it would otherwise land inside the preceding section.
  # Samba's `include` does not glob — exactly one file. smbctl is the only writer and validates with testparm before replacing it, so it is never invalid here.
  echo "include = $SMB_STATE_DIR/dynamic.conf"
}

# smbpasswd reads smb.conf, so it must run after the config is rendered.
set_password() {
  printf '%s\n%s\n' "$2" "$2" | smbpasswd -s -a "$1" >/dev/null
  smbpasswd -e "$1" >/dev/null
}

# Mirrors this process's stdout/stderr into a file under CONTAINER_LOG_DIR,
# in  addition to `docker logs`, so entrypoint messages and smbd's foreground output survive container restarts.
# Uses a fifo + tee instead of `exec >  >(...)` because this script runs under /bin/sh, which has no process substitution.
setup_container_log() {
  fifo=/tmp/container-log.fifo
  rm -f "$fifo"
  mkfifo "$fifo"
  tee -a "$CONTAINER_LOG_DIR/container.log" < "$fifo" &
  exec > "$fifo" 2>&1
  rm -f "$fifo"
}

main() {
  require_env SMB_READ_USER SMB_READ_PASSWORD SMB_WRITE_USER SMB_WRITE_PASSWORD \
    SMB_UID SMB_GID SMB_LOG_DIR CONTAINER_LOG_DIR SMB_STATE_DIR SHARE_NAME_1st
  mkdir -p "$SMB_LOG_DIR" "$CONTAINER_LOG_DIR" "$SMB_STATE_DIR" /var/lib/samba/private /run/samba
  # Create it unconditionally rather than relying on how Samba treats an `include`pointing at a missing file.
  touch "$SMB_STATE_DIR/dynamic.conf"
  setup_container_log

  ensure_accounts
  resolve_vfs_objects

  render_config > "$CONF"
  # One single die, as before: dynamic.conf is only ever written by smbctl, which  validates a draft before replacing it (execution-plan.md P1.2),
  # so a broken file here means someone edited it by hand — same failure mode as putting garbage in config.env.
  # Note testparm only fails on a bad value of a known parameter or a broken section header;
  # junk lines it ignores silently, so this gate is exactly "would smbd fail to load", not "is the file sensible".
  testparm -s "$CONF" >/dev/null 2>&1 || die "generated smb.conf is invalid; run: testparm -s $CONF"

  # After render_config: pdbedit reads smb.conf to find the passdb backend.
  reconcile_accounts

  set_password "$SMB_WRITE_USER" "$SMB_WRITE_PASSWORD"
  set_password "$SMB_READ_USER" "$SMB_READ_PASSWORD"
  log "ready: writer=${SMB_WRITE_USER}, reader=${SMB_READ_USER}, port=445, shares=${SHARE_COUNT}"
  exec smbd --foreground --no-process-group
}

main "$@"
