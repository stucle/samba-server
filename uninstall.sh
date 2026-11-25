#!/usr/bin/env bash
# Removes what install.sh installed for the Samba server - and nothing else.
# Run as root (sudo) from anywhere; safe to re-run (steps already done are skipped).
#
#   sudo bash ~/samba-ubuntu-kit/uninstall.sh [options]
#
# Default (no options):
#   - stops + removes samba-logroll (timer, service, script, logroll.conf, state dir)
#   - stops smbd/nmbd, removes the kit's smbd drop-in and its 'tailscale serve' :445 entry
#   - restores /etc/samba/smb.conf to the version that was there before the kit
#     (the oldest smb.conf.bak.*), only if the current file is still the kit's
#   - apt-get remove samba samba-common-bin smbclient, but ONLY if apt would remove
#     nothing else (otherwise it aborts and touches no package)
#
# Options:
#   --keep-packages   keep the packages; just stop + disable smbd and nmbd
#   --purge           apt-get purge instead of remove (samba-common is NOT purged:
#                     its postrm deletes all of /etc/samba, /var/lib/samba, /var/log/samba),
#                     and delete the Samba user DB (passdb.tdb, secrets.tdb)
#   --remove-users    delete the Unix accounts reader/groot and their groups
#   --dry-run         print what would be done, change nothing
#   -y, --yes         don't ask for confirmation
#
# NEVER touched: the share (/home/ubuntu/samba by default, <home>/samba with --share-user; data, log/, log/archived/), Tailscale,
# the share owner's home permissions, /var/local itself, the package's /etc/logrotate.d/samba, samba-common, *.bak.* files, /root/samba-custom.logrotate.removed.*, other packages.
set -euo pipefail
cd "$(dirname "$0")"

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN:  $*" >&2; }

KEEP_PKGS=0 PURGE=0 RM_USERS=0 DRY=0 YES=0
for a in "$@"; do
  case $a in
    --keep-packages) KEEP_PKGS=1 ;;
    --purge)         PURGE=1 ;;
    --remove-users)  RM_USERS=1 ;;
    --dry-run)       DRY=1 ;;
    -y|--yes)        YES=1 ;;
    -h|--help)       sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $a (see --help)" ;;
  esac
done
((KEEP_PKGS && PURGE)) && die "--keep-packages and --purge exclude each other"

[[ $EUID -eq 0 ]] || die "run as root: sudo bash $0"
command -v python3 >/dev/null || die "python3 is required (reads to-copy/manifest.json)"

# --- must match install.sh -------------------------------------------------------
SVC=smbd
PKGS=(samba samba-common-bin smbclient)
KIT_USERS=(reader groot)
# the share is wherever install.sh put it: read it back from the roller config it generated; if that is already gone, from the kit key SHARE_USER in smb.conf
SHARE_DIR=$(sed -n 's|^LOG_DIR=||p' /etc/samba/logroll.conf 2>/dev/null || true); SHARE_DIR=${SHARE_DIR%/log}
if [[ -z $SHARE_DIR ]]; then   # logroll.conf already gone: same rule as install.sh - kit key SHARE_USER in smb.conf -> <its home>/samba
  _u=$(sed -n 's/^[[:space:]]*SHARE_USER[[:space:]]*=[[:space:]]*//p' smb.conf | sed 's/[[:space:]]*$//')
  _h=$(getent passwd "$_u" 2>/dev/null | cut -d: -f6) || true
  [[ -n $_u && -n $_h ]] || die "cannot tell where the share is (no /etc/samba/logroll.conf; SHARE_USER '$_u' in smb.conf has no home)"
  SHARE_DIR=$_h/samba
fi
LOGROLL_STATE_DIR=/var/local/lib/samba-logroll
SMB_CONF=/etc/samba/smb.conf
KIT_FILES=(
  /etc/systemd/system/samba-logroll.timer
  /etc/systemd/system/samba-logroll.service
  /usr/local/sbin/samba-logroll
  /etc/samba/logroll.conf
  /run/samba-logroll.lock
)
STAMP=$(date +%Y%m%d%H%M%S)
# files copied by install.sh come from to-copy/manifest.json (same validator as install.sh)
MANIFEST=$(python3 -I manifest.py to-copy/manifest.json) || die "to-copy/manifest.json is invalid; nothing was changed"

# manifest_pass POLICY : handle every entry whose "uninstall" is POLICY (remove | purge)
manifest_pass() {
  local policy=$1 fn sp dest mode owner dmode ow bk guard verify grp un dst
  while IFS=$'\t' read -r fn sp dest mode owner dmode ow bk guard verify grp un; do
    [[ $un == "$policy" ]] || continue
    dst=$dest/$fn
    [[ -e $dst ]] || continue
    if [[ $policy == remove ]] && ! cmp -s "$sp" "$dst"; then
      warn "$dst differs from the kit's copy (edited by hand?) - left in place"; continue
    fi
    run rm -f -- "$dst"; ((DRY)) || echo "  removed: $dst"
    # only if nothing else lives there (the drop-in dir; /var/lib/samba/private is the package's and never empty-checked here)
    [[ $policy == remove && -d $dest ]] && run rmdir --ignore-fail-on-non-empty "$dest"
  done <<<"$MANIFEST"
  return 0
}

run() { if ((DRY)); then echo "  [dry-run] $*"; else "$@"; fi; }
unit_exists() { [[ -n $(systemctl list-unit-files --no-legend "$1" 2>/dev/null) ]]; }

installed_pkgs() {
  local p
  for p in "${PKGS[@]}"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed" && echo "$p"
  done
  return 0
}
mapfile -t INSTALLED < <(installed_pkgs)

# ---- plan + confirm -----------------------------------------------------------
echo "This removes the kit's Samba server from $(hostname):"
echo "  - samba-logroll timer/service/script/config/state"
echo "  - files from to-copy/manifest.json with uninstall=remove (if still identical to the kit's copy):"
awk -F'\t' '$12=="remove"{print "      " $3 "/" $1}' <<<"$MANIFEST"
echo "  - $SMB_CONF -> restored to the pre-kit version (if it is still the kit's)"
if ((KEEP_PKGS)); then
  echo "  - packages kept; smbd and nmbd stopped + disabled"
elif ((${#INSTALLED[@]})); then
  echo "  - apt-get $( ((PURGE)) && echo purge || echo remove ) ${INSTALLED[*]}"
fi
((PURGE))    && awk -F'\t' '$12=="purge"{print "  - credential file (purge): " $3 "/" $1}' <<<"$MANIFEST"
((RM_USERS)) && echo "  - Unix users/groups: ${KIT_USERS[*]}"
echo "Kept: $SHARE_DIR (data + log/), Tailscale, samba-common, other packages."
if ((!DRY && !YES)); then
  [[ -t 0 ]] || die "no terminal to confirm on; re-run with -y"
  read -r -p "Continue? [y/N] " ans
  [[ $ans =~ ^[Yy]$ ]] || { echo "aborted"; exit 1; }
fi

# ---- packages: check BEFORE changing anything ---------------------------------
# apt also removes every package that depends on these; refuse if that is anything else.
if ((!KEEP_PKGS && ${#INSTALLED[@]})); then
  echo "== checking what apt would remove =="
  mapfile -t WOULD < <(apt-get -s remove "${INSTALLED[@]}" 2>/dev/null | awk '/^Remv /{print $2}' | sed 's/:.*//')
  EXTRA=()
  for w in "${WOULD[@]}"; do
    [[ " ${INSTALLED[*]} " == *" $w "* ]] || EXTRA+=("$w")
  done
  if ((${#EXTRA[@]})); then
    die "apt would also remove other packages that depend on Samba: ${EXTRA[*]}
       Nothing was changed. Re-run with --keep-packages to remove only the kit's server setup."
  fi
  echo "  ok: only ${INSTALLED[*]}"
fi

# ---- 1. log roller ------------------------------------------------------------
echo "== samba-logroll =="
for u in samba-logroll.timer samba-logroll.service; do
  if unit_exists "$u"; then
    run systemctl disable --now "$u" 2>/dev/null || true
    run systemctl reset-failed "$u" 2>/dev/null || true
  fi
done
for f in "${KIT_FILES[@]}"; do
  if [[ -e $f ]]; then run rm -f -- "$f"; ((DRY)) || echo "  removed: $f"; fi
done
if [[ -d $LOGROLL_STATE_DIR ]]; then
  run rm -rf -- "$LOGROLL_STATE_DIR"; ((DRY)) || echo "  removed: $LOGROLL_STATE_DIR"
fi
# its parent /var/local/lib may have existed before the kit -> left alone

# ---- 2. smbd / nmbd + drop-in ---------------------------------------------------
echo "== $SVC =="
for u in "$SVC" nmbd; do
  if unit_exists "$u.service"; then
    if ((KEEP_PKGS)); then run systemctl disable --now "$u" 2>/dev/null || true
    else                   run systemctl stop "$u" 2>/dev/null || true
    fi
  fi
done
manifest_pass remove
run systemctl daemon-reload
# the tailnet :445 -> localhost:445 forward that restart.sh published (only if it is there)
if command -v tailscale >/dev/null 2>&1 && tailscale serve status 2>/dev/null | grep -q ':445'; then
  run tailscale serve --tcp 445 off || warn "could not remove the tailscale serve entry for :445 - sudo tailscale serve --tcp 445 off"
  ((DRY)) || echo "  removed: tailscale serve :445"
fi

# ---- 3. smb.conf ----------------------------------------------------------------
echo "== $SMB_CONF =="
if [[ -f $SMB_CONF ]] && grep -q "$SHARE_DIR/log/" "$SMB_CONF"; then
  # install.sh backs the old file up as smb.conf.bak.<YYYYmmddHHMMSS> before its first
  # install, so the oldest backup is what was there before the kit.
  ORIG=$(find /etc/samba -maxdepth 1 -name 'smb.conf.bak.[0-9]*' -printf '%f\n' 2>/dev/null | sort | head -n1)
  if [[ -n $ORIG ]] && ! grep -q "$SHARE_DIR/log/" "/etc/samba/$ORIG"; then
    run cp -a "$SMB_CONF" "$SMB_CONF.bak.$STAMP"
    run cp -a "/etc/samba/$ORIG" "$SMB_CONF"
    ((DRY)) || echo "  restored pre-kit version from /etc/samba/$ORIG (kit version saved as $SMB_CONF.bak.$STAMP)"
  else
    warn "no pre-kit backup of $SMB_CONF found - the kit's version is left in place"
  fi
else
  echo "  not the kit's version (or absent) - left alone"
fi

# ---- 4. Samba user DB (credential material) -------------------------------------
echo "== Samba user DB =="
if ((PURGE)); then
  manifest_pass purge
else
  while read -r f; do
    if [[ -e $f ]]; then warn "$f (credential material) kept; use --purge to delete it"; fi
  done < <(awk -F'\t' '$12=="purge"{print $3 "/" $1}' <<<"$MANIFEST")
fi

# ---- 5. packages ----------------------------------------------------------------
if ((!KEEP_PKGS && ${#INSTALLED[@]})); then
  echo "== packages =="
  export DEBIAN_FRONTEND=noninteractive
  run apt-get "$( ((PURGE)) && echo purge || echo remove )" -y "${INSTALLED[@]}"
  echo "  note: no autoremove is run; check 'apt-get -s autoremove' yourself if wanted"
fi

# ---- 6. Unix users --------------------------------------------------------------
if ((RM_USERS)); then
  echo "== users/groups =="
  for u in "${KIT_USERS[@]}"; do
    if id -u "$u" >/dev/null 2>&1; then
      pgrep -u "$u" >/dev/null && { warn "$u still has running processes - skipped"; continue; }
      run userdel "$u"; ((DRY)) || echo "  removed user: $u"
    fi
    # install.sh created the group separately; drop it only if nobody uses it any more
    if getent group "$u" >/dev/null; then
      gid=$(getent group "$u" | cut -d: -f3)
      members=$(getent group "$u" | cut -d: -f4)
      if [[ -z $members ]] && ! getent passwd | awk -F: -v g="$gid" '$4==g{f=1} END{exit !f}'; then
        run groupdel "$u"; ((DRY)) || echo "  removed group: $u"
      else
        warn "group $u still in use - left in place"
      fi
    fi
  done
  echo "  note: files in $SHARE_DIR owned by these users keep their numeric uid"
fi

cat <<EOF

Done. Left untouched on purpose:
  - $SHARE_DIR (share data, log/, log/archived/) - delete by hand if wanted
  - Tailscale, cloud firewall, the share owner's home permissions
  - samba-common, /etc/samba/*.bak.*, /var/lib/samba (except with --purge: passdb/secrets)
  - users added by hand (onboard) - remove them with: smbpasswd -x <user>; userdel <user>
EOF
