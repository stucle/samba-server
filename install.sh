#!/usr/bin/env bash
# Puts the maverick Samba server config on disk (Debian/Ubuntu). Run as root (sudo) from anywhere; safe to re-run.
# It does NOT restart or start smbd (it only stops it before restoring the user DB): run restart.sh afterwards.
#   - config files are only rewritten when their content changed
#   - to-copy/manifest.json lists the plain files copied to the host (drop-in, user DB);
#      the user DB (passdb.tdb/secrets.tdb) is guarded: it is restored only while the host has no Samba users, so users managed by hand (onboard/offboard) are preserved.
set -euo pipefail
cd "$(dirname "$0")"

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN:  $*" >&2; }

[[ $EUID -eq 0 ]] || die "run as root: sudo bash $0"

# Share owner. Its home holds the share (<home>/samba) and a group of the same name owns it.
# Default = kit key SHARE_USER in smb.conf (ubuntu). Override for one host: sudo bash install.sh --share-user ubuntu
kit_key() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" smb.conf | sed 's/[[:space:]]*$//'; }
SHARE_USER_OPT=${SHARE_USER:-}
while (($#)); do
  case $1 in
    --share-user) SHARE_USER_OPT=${2:-}; [[ -n $SHARE_USER_OPT ]] || die "--share-user needs a user name"; shift 2 ;;
    *) die "unknown option: $1 (only --share-user NAME)" ;;
  esac
done
SHARE_USER=${SHARE_USER_OPT:-$(kit_key SHARE_USER)}
[[ $SHARE_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || die "SHARE_USER '$SHARE_USER' is not a valid account name"
SHARE_HOME=$(getent passwd "$SHARE_USER" | cut -d: -f6) || true
[[ -n $SHARE_HOME && $SHARE_HOME == /home/* && $SHARE_HOME =~ ^/home/[A-Za-z0-9._-]+$ ]] || die "user $SHARE_USER not found, or its home ('$SHARE_HOME') is not /home/<name>"
getent group "$SHARE_USER" >/dev/null || die "group $SHARE_USER not found (the share is owned by group $SHARE_USER)"
SHARE_DIR=$SHARE_HOME/samba
echo "share: $SHARE_DIR (owner/group $SHARE_USER)"
SVC=smbd
# Roller state: See documentation/guideline.md > Logging
#  - /usr/local is for locally-installed software,
#  - and on Debian/Ubuntu  /var/local is where its variable data belongs;
#  - /var/lib/samba* is the samba package's namespace.
LOGROLL_STATE_DIR=/var/local/lib/samba-logroll
STAMP=$(date +%Y%m%d%H%M%S)

# install_if_changed SRC DST [MODE]  -> installs root:root (default 0644), backs up the old file
install_if_changed() {
  local src=$1 dst=$2 mode=${3:-0644}
  if [[ -e $dst ]] && cmp -s "$src" "$dst"; then
    echo "  unchanged: $dst"
    return 0
  fi
  [[ -e $dst ]] && cp -a "$dst" "$dst.bak.$STAMP" && echo "  backup:    $dst.bak.$STAMP"
  install -m "$mode" -o root -g root "$src" "$dst"
  echo "  installed: $dst"
}

# --- to-copy/manifest.json -------------------------------------------------------
# manifest.py validates the whole file and flattens it to TSV; nothing is touched if it is invalid.
# guard_<name>  : returns 0 = apply the entries of this unit, 1 = skip them (not an error).
# pre_<guard>   : runs once, right before the first entry of a unit that passed its guard is replaced.
# verify_<name> : run after the unit was copied; failure -> files moved aside, install stops.
guard_samba_passdb_no_users() {
  # no passdb.tdb, or one without users (apt starts smbd after install and creates an empty one) -> restore.
  # A passdb that exists but cannot be read is never touched blind.
  [[ -e /var/lib/samba/private/passdb.tdb ]] || return 0
  # stdout only: pdbedit prints noise ("added interface ...") on stderr, which must not make an empty passdb look like it has users
  local users err rc=0
  err=$(mktemp)
  users=$(pdbedit -L 2>"$err") || rc=$?
  if ((rc)); then users=$(<"$err"); rm -f "$err"; die "/var/lib/samba/private/passdb.tdb exists but pdbedit cannot read it - not touching it, check by hand: $users"; fi
  rm -f "$err"
  if [[ -z $users ]]; then return 0; fi
  echo "  passdb.tdb already has users -> keeping them (no restore)"
  return 1
}
pre_samba_passdb_no_users() { systemctl stop "$SVC" 2>/dev/null || true; }
verify_samba_passdb_readable() {
  pdbedit -L >/dev/null 2>&1 || return 1
  echo "  restored. Samba users:"; pdbedit -L 2>/dev/null | sed 's/^/    /'
}

apply_manifest() {
  local rows fn sp dest mode owner dmode ow bk guard verify grp un i key dst f
  rows=$(python3 -I manifest.py to-copy/manifest.json) || die "to-copy/manifest.json is invalid; nothing was copied"
  local -A U_SKIP U_CHANGED U_VERIFY U_FILES U_PRE
  local -a ORDER=()
  i=0
  while IFS=$'\t' read -r fn sp dest mode owner dmode ow bk guard verify grp un; do
    i=$((i+1))
    key=$grp; [[ $grp != - ]] || key="entry$i"
    if [[ -z ${U_SKIP[$key]+x} ]]; then
      ORDER+=("$key"); U_CHANGED[$key]=0; U_VERIFY[$key]=$verify; U_FILES[$key]=""; U_PRE[$key]=0; U_SKIP[$key]=0
      if [[ $guard != - ]] && ! "guard_${guard//-/_}"; then U_SKIP[$key]=1; fi
    fi
    dst=$dest/$fn
    if [[ ${U_SKIP[$key]} -eq 1 ]]; then echo "  skipped (guard $guard): $dst"; continue; fi
    if [[ -e $dst ]]; then
      if [[ $ow == ifAbsent ]]; then echo "  exists, kept: $dst"; continue; fi
      if [[ $ow == ifChanged ]] && cmp -s "$sp" "$dst"; then echo "  unchanged: $dst"; continue; fi
    fi
    if [[ $guard != - && ${U_PRE[$key]} -eq 0 ]]; then "pre_${guard//-/_}"; U_PRE[$key]=1; fi
    [[ -d $dest ]] || install -d -m "$dmode" -o "${owner%%:*}" -g "${owner##*:}" "$dest"
    if [[ -e $dst && $bk == 1 ]]; then cp -a "$dst" "$dst.bak.$STAMP"; echo "  backup:    $dst.bak.$STAMP"; fi
    install -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$sp" "$dst"
    echo "  installed: $dst"
    U_CHANGED[$key]=1; U_FILES[$key]+="$dst "
  done <<<"$rows"
  for key in "${ORDER[@]}"; do
    [[ ${U_CHANGED[$key]} -eq 1 && ${U_VERIFY[$key]} != - ]] || continue
    if ! "verify_${U_VERIFY[$key]//-/_}"; then
      for f in ${U_FILES[$key]}; do mv "$f" "$f.failed.$STAMP"; done
      die "${U_VERIFY[$key]} failed after copying (${U_FILES[$key]}); moved aside as *.failed.$STAMP. Re-create users with smbpasswd -a, then re-run."
    fi
  done
}

echo "== installing samba =="
PKGS=(samba samba-common-bin smbclient python3)   # python3: reads to-copy/manifest.json (manifest.py)
MISSING=()
for p in "${PKGS[@]}"; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed" || MISSING+=("$p")
done
if ((${#MISSING[@]})); then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -o Dpkg::Options::=--force-confold "${MISSING[@]}"
else
  echo "  already installed: ${PKGS[*]}"
fi

echo "== creating groups/users =="
# fixed ids for parity with the source host; fall back to system-assigned if taken
getent group reader >/dev/null || groupadd -g 1002 reader 2>/dev/null || groupadd reader
getent group groot  >/dev/null || groupadd -g 1003 groot  2>/dev/null || groupadd groot
id -u reader >/dev/null 2>&1 || useradd -u 1001 -g reader -s /usr/sbin/nologin -M reader 2>/dev/null \
  || useradd -g reader -s /usr/sbin/nologin -M reader
id -u groot  >/dev/null 2>&1 || useradd -u 1002 -g groot  -s /usr/sbin/nologin -M groot  2>/dev/null \
  || useradd -g groot  -s /usr/sbin/nologin -M groot
usermod -aG "$SHARE_USER" reader
usermod -aG "$SHARE_USER" groot

echo "== share + log directories =="
# Ubuntu cloud images create /home/ubuntu as 0750, so group x is already there; this is a guard in case the host was built differently.
# reader/groot are in group ubuntu and need to traverse it (traverse only, not listing).
chmod g+x "$SHARE_HOME"
install -d -m 0770 -o "$SHARE_USER" -g "$SHARE_USER" "$SHARE_DIR"
install -d -m 2775 -o "$SHARE_USER" -g "$SHARE_USER" "$SHARE_DIR/log"
# current log files live in log/, everything the roller archives goes to log/archived/
install -d -m 2775 -o "$SHARE_USER" -g "$SHARE_USER" "$SHARE_DIR/log/archived"
# roller state (day the current file was started, stale-fd marker) - kept outside the share.
# /var/local itself is left exactly as Ubuntu ships it (2775 root:staff);
# it is only created if a minimal image lacks it. The state dir inherits that setgid bit from its parent (install -d lets it through, and a numeric chmod mode does not clear setgid on a directory),
# so it is cleared explicitly on the state dir only.
[[ -d $(dirname "$LOGROLL_STATE_DIR") ]] || install -d -m 2775 -o root -g staff "$(dirname "$LOGROLL_STATE_DIR")"
install -d -m 0750 -o root -g root "$LOGROLL_STATE_DIR"
chmod g-s "$LOGROLL_STATE_DIR"

echo "== AppArmor =="
# No SELinux on Ubuntu. Ubuntu's samba package ships no enabled smbd profile (that is apparmor-profiles-extra), so normally there is nothing to do - but if a profile IS loaded,
# a share outside /var/lib/samba needs an explicit rule. This script only reports it; it never edits AppArmor policy.
if command -v aa-status >/dev/null 2>&1 && aa-status --enabled 2>/dev/null; then
  if aa-status 2>/dev/null | grep -qE '^\s+/usr/sbin/smbd$'; then
    warn "an AppArmor profile for /usr/sbin/smbd is loaded (enforce or complain mode)."
    warn "  verify it allows $SHARE_DIR/** rw, e.g. add to /etc/apparmor.d/local/usr.sbin.smbd:"
    warn "    $SHARE_DIR/** rwk,"
    warn "  then: sudo apparmor_parser -r /etc/apparmor.d/usr.sbin.smbd"
  else
    echo "  enabled, no profile for smbd - nothing to do"
  fi
else
  echo "  not enabled - nothing to do"
fi

echo "== smb.conf =="
# Kit-only keys in smb.conf (KEY = value): read them, substitute @KEY@ placeholders, strip the key lines.
KIT_KEYS=(SHARE_USER HOSTS_ALLOW SAMBA_LOG_PREFIX SAMBA_LOG_MAX_MB ROTATE_LOG_PREFIX ROTATE_LOG_MAX_MB LOG_KEEP_DAYS CRON_LOG ROLL_DAILY_AT)
declare -A KV
SED_ARGS=(-e "s|@SHARE_DIR@|$SHARE_DIR|g")   # derived from SHARE_USER, not a key in smb.conf
for k in "${KIT_KEYS[@]}"; do
  KV[$k]=$(kit_key "$k")
  [[ $k == SHARE_USER ]] && KV[$k]=$SHARE_USER   # --share-user / env override wins over the smb.conf default
  [[ -n "${KV[$k]}" ]] || die "$k not set in smb.conf"
  SED_ARGS+=(-e "/^[[:space:]]*$k[[:space:]]*=/d" -e "s|@$k@|${KV[$k]}|g")
done
for k in SAMBA_LOG_PREFIX ROTATE_LOG_PREFIX; do
  [[ ${KV[$k]} =~ ^[A-Za-z0-9_]+$ ]] || die "$k must match [A-Za-z0-9_]+ (got '${KV[$k]}')"
done
[[ ${KV[ROLL_DAILY_AT]} =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "ROLL_DAILY_AT must be HH:MM, 24h (got '${KV[ROLL_DAILY_AT]}')"
[[ ${KV[SAMBA_LOG_PREFIX]} != "${KV[ROTATE_LOG_PREFIX]}" ]] || die "SAMBA_LOG_PREFIX and ROTATE_LOG_PREFIX must differ"
for k in SAMBA_LOG_MAX_MB ROTATE_LOG_MAX_MB LOG_KEEP_DAYS CRON_LOG; do
  [[ ${KV[$k]} =~ ^[1-9][0-9]*$ ]] || die "$k must be a positive integer (got '${KV[$k]}')"
done
RENDERED=$(mktemp)
LOGROLL_CONF_TMP=$(mktemp)
TIMER_TMP=$(mktemp)
trap 'rm -f "$RENDERED" "$LOGROLL_CONF_TMP" "$TIMER_TMP"' EXIT
sed "${SED_ARGS[@]}" smb.conf > "$RENDERED"
grep -q '@[A-Z_]*@' "$RENDERED" && die "unresolved placeholder in rendered smb.conf"
testparm -s "$RENDERED" >/dev/null 2>&1 || { testparm -s "$RENDERED" >&2 || true; die "rendered smb.conf is invalid"; }
install_if_changed "$RENDERED" /etc/samba/smb.conf

echo "== log rolling (current file in log/, archived/<prefix>-<date>-<index>.log) =="
# replaces any earlier logrotate setup; move it away if one was installed
if [[ -e /etc/logrotate.d/samba-custom ]]; then
  mv /etc/logrotate.d/samba-custom "/root/samba-custom.logrotate.removed.$STAMP"
  echo "  moved old /etc/logrotate.d/samba-custom to /root/samba-custom.logrotate.removed.$STAMP"
fi
# Ubuntu's samba package ships /etc/logrotate.d/samba for /var/log/samba/*.log only; it does not touch this share's log dir, so it is left alone.
cat > "$LOGROLL_CONF_TMP" <<EOF
# generated by install.sh from the kit-only keys in smb.conf - do not edit by hand
LOG_DIR=$SHARE_DIR/log
ARCHIVE_DIR=$SHARE_DIR/log/archived
STATE_DIR=$LOGROLL_STATE_DIR
SMB_SERVICE=$SVC
SAMBA_PREFIX=${KV[SAMBA_LOG_PREFIX]}
SAMBA_MAX_MB=${KV[SAMBA_LOG_MAX_MB]}
ROTATE_PREFIX=${KV[ROTATE_LOG_PREFIX]}
ROTATE_MAX_MB=${KV[ROTATE_LOG_MAX_MB]}
KEEP_DAYS=${KV[LOG_KEEP_DAYS]}
OWNER_GROUP=$SHARE_USER
EOF
install_if_changed "$LOGROLL_CONF_TMP" /etc/samba/logroll.conf
install_if_changed logroll/samba-logroll.sh      /usr/local/sbin/samba-logroll 0755
install_if_changed logroll/samba-logroll.service /etc/systemd/system/samba-logroll.service
sed -e "s|@CRON_LOG@|${KV[CRON_LOG]}|g" -e "s|@ROLL_DAILY_AT@|${KV[ROLL_DAILY_AT]}|g" logroll/samba-logroll.timer > "$TIMER_TMP"
grep -q '@[A-Z_]*@' "$TIMER_TMP" && die "unresolved placeholder in logroll/samba-logroll.timer"
install_if_changed "$TIMER_TMP" /etc/systemd/system/samba-logroll.timer

echo "== to-copy (manifest) =="
apply_manifest

cat <<'EOF'

install.sh done - NOTHING IS LIVE YET: new config / drop-in / user DB are on disk, smbd still runs the old state.
Next: sudo bash restart.sh   (daemon-reload, enable, restart smbd + log-roll timer)
EOF
