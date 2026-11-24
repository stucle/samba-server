#!/usr/bin/env bash
# Rebuilds the maverick Samba server config on Ubuntu. Run as root (sudo) from anywhere; safe to re-run (idempotent):
#   - config files are only rewritten when their content changed
#   - the Samba user DB (passdb.tdb/secrets.tdb) is restored ONLY on first
#     install; if it already exists it is never touched, so users managed by
#     the onboard/offboard scripts are preserved.
set -euo pipefail
cd "$(dirname "$0")"

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN:  $*" >&2; }

[[ $EUID -eq 0 ]] || die "run as root: sudo bash $0"
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == ubuntu ]] || die "Ubuntu only (found: ${PRETTY_NAME:-unknown})"
case "${VERSION_ID:-}" in
  22.04|24.04) ;;
  *) die "tested on Ubuntu 22.04 and 24.04 only (found: ${VERSION_ID:-unknown}); extend this check deliberately" ;;
esac

SHARE_USER=ubuntu
SHARE_HOME=$(getent passwd "$SHARE_USER" | cut -d: -f6) || true
[[ "$SHARE_HOME" == /home/ubuntu ]] || die "user $SHARE_USER not found or home is not /home/ubuntu (smb.conf hard-codes it)"
SHARE_DIR=$SHARE_HOME/samba
SVC=smbd
# Roller state: See guideline.md > Logging
#  - /usr/local is for locally-installed software,
#  - and on Debian/Ubuntu  /var/local is where its variable data belongs;
#  - /var/lib/samba* is the samba package's namespace.
LOGROLL_STATE_DIR=/var/local/lib/samba-logroll
PRIV=/var/lib/samba/private
STAMP=$(date +%Y%m%d%H%M%S)
RESTART_NEEDED=0
LAST_CHANGED=0

# install_if_changed SRC DST [restart] [MODE]  -> installs root:root (default 0644), backs up the old file; with a 3rd arg "restart" a change also schedules a restart of smbd
install_if_changed() {
  local src=$1 dst=$2 restart=${3:-} mode=${4:-0644}
  LAST_CHANGED=0
  if [[ -e $dst ]] && cmp -s "$src" "$dst"; then
    echo "  unchanged: $dst"
    return 0
  fi
  [[ -e $dst ]] && cp -a "$dst" "$dst.bak.$STAMP" && echo "  backup:    $dst.bak.$STAMP"
  install -m "$mode" -o root -g root "$src" "$dst"
  echo "  installed: $dst"
  LAST_CHANGED=1
  [[ -z $restart ]] || RESTART_NEEDED=1
}

echo "== installing samba =="
PKGS=(samba samba-common-bin smbclient)
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
kit_key() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" smb.conf | sed 's/[[:space:]]*$//'; }
KIT_KEYS=(HOSTS_ALLOW SAMBA_LOG_PREFIX SAMBA_LOG_MAX_MB ROTATE_LOG_PREFIX ROTATE_LOG_MAX_MB LOG_KEEP_DAYS CRON_LOG ROLL_DAILY_AT)
declare -A KV
SED_ARGS=()
for k in "${KIT_KEYS[@]}"; do
  KV[$k]=$(kit_key "$k")
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
install_if_changed "$RENDERED" /etc/samba/smb.conf restart

echo "== log rolling (current file in log/, archived/<prefix>-<date>-<index>.log) =="
# replaces any earlier logrotate setup; move it away if one was installed
if [[ -e /etc/logrotate.d/samba-custom ]]; then
  mv /etc/logrotate.d/samba-custom "/root/samba-custom.logrotate.removed.$STAMP"
  echo "  moved old /etc/logrotate.d/samba-custom to /root/samba-custom.logrotate.removed.$STAMP"
fi
# Ubuntu's samba package ships /etc/logrotate.d/samba for /var/log/samba/*.log only; it does not touch this share's log dir, so it is left alone.
cat > "$LOGROLL_CONF_TMP" <<EOF
# generated by setup.sh from the kit-only keys in smb.conf - do not edit by hand
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
install_if_changed samba-logroll.sh      /usr/local/sbin/samba-logroll "" 0755
install_if_changed samba-logroll.service /etc/systemd/system/samba-logroll.service
sed -e "s|@CRON_LOG@|${KV[CRON_LOG]}|g" -e "s|@ROLL_DAILY_AT@|${KV[ROLL_DAILY_AT]}|g" samba-logroll.timer > "$TIMER_TMP"
grep -q '@[A-Z_]*@' "$TIMER_TMP" && die "unresolved placeholder in samba-logroll.timer"
install_if_changed "$TIMER_TMP" /etc/systemd/system/samba-logroll.timer
TIMER_CHANGED=$LAST_CHANGED

echo "== systemd drop-in =="
install -d /etc/systemd/system/smbd.service.d
install_if_changed etc-systemd-smbd-dropin/limits.conf /etc/systemd/system/smbd.service.d/limits.conf restart

echo "== samba user/password DB =="
install -d -m 0700 -o root -g root "$PRIV"
if [[ -e $PRIV/passdb.tdb ]]; then
  echo "  passdb.tdb already exists -> keeping existing users (no restore)"
else
  systemctl stop "$SVC" 2>/dev/null || true
  # a secrets.tdb auto-created by an earlier start must not mix with the restored passdb
  [[ -e $PRIV/secrets.tdb ]] && mv "$PRIV/secrets.tdb" "$PRIV/secrets.tdb.bak.$STAMP"
  tar -C "$PRIV" --no-same-owner -xf var-lib-samba-private/private.tar passdb.tdb secrets.tdb
  chown root:root "$PRIV/passdb.tdb" "$PRIV/secrets.tdb"
  chmod 600 "$PRIV/passdb.tdb" "$PRIV/secrets.tdb"
  # The kit comes from Samba 4.19 (= Ubuntu 24.04). On 22.04 (4.15) verify it can read the DB
  if pdbedit -L >/dev/null 2>&1; then
    echo "  restored. Samba users:"; pdbedit -L | sed 's/^/    /'
  else
    mv "$PRIV/passdb.tdb"  "$PRIV/passdb.tdb.failed.$STAMP"
    mv "$PRIV/secrets.tdb" "$PRIV/secrets.tdb.failed.$STAMP"
    die "restored passdb is not readable by this Samba version; moved aside (*.failed.$STAMP). Re-create users with smbpasswd -a, then re-run."
  fi
  RESTART_NEEDED=1
fi

echo "== enable + start =="
ip link show tailscale0 >/dev/null 2>&1 || warn "interface tailscale0 not found - Samba will only listen on loopback until Tailscale is up (then: systemctl restart $SVC)"
systemctl daemon-reload
systemctl enable "$SVC"
/usr/local/sbin/samba-logroll        # creates log/<prefix>.log before smbd starts
systemctl enable --now samba-logroll.timer
if [[ $TIMER_CHANGED -eq 1 ]]; then systemctl restart samba-logroll.timer; echo "  samba-logroll.timer restarted (every ${KV[CRON_LOG]} min + daily at ${KV[ROLL_DAILY_AT]})"; fi
if systemctl is-active --quiet "$SVC"; then
  if [[ $RESTART_NEEDED -eq 1 ]]; then systemctl restart "$SVC"; echo "  restarted $SVC"; else echo "  $SVC already running, nothing changed"; fi
else
  systemctl start "$SVC"; echo "  started $SVC"
fi
systemctl is-enabled --quiet nmbd 2>/dev/null && warn "nmbd is enabled (NetBIOS name service, as the samba package set it). It honours the same 'interfaces'/'bind interfaces only', so it stays off the public NIC. Not needed by SMB over Tailscale: sudo systemctl disable --now nmbd"
testparm -s 2>/dev/null | sed -n '/^\[global\]/,/^$/p' | grep -E 'hosts allow|interfaces|bind interfaces|log file|max log size' || true

cat <<'EOF'

Done. Still manual:
  1. Tailscale installed + joined to the tailnet (sudo tailscale up) - hosts allow relies on it.
  2. Check the cloud firewall / security group - do not expose port 445 publicly.
  3. Verify: smbclient -L localhost -U reader
EOF
