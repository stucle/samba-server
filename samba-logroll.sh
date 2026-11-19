#!/usr/bin/env bash
# samba-logroll: size-capped log archiving for Samba.
#
#   current:   <LOG_DIR>/<prefix>.log                       a real file, appended to
#   archived:  <LOG_DIR>/archived/<prefix>-<YYYYMMDD>-<index>.log
#
# Two log streams share the same folder and the same logic:
#   samba   written by smbd; smbd always opens <LOG_DIR>/<SAMBA_PREFIX>.log
#           (the unit to signal is SMB_SERVICE in the conf: smbd on Ubuntu)
#   rotate  this script's own activity log (archiving, reloads, pruning)
#
# Rule: keep appending to <prefix>.log until it reaches the cap, or until the day
# it was started is no longer today; then move it to archived/ under the day it
# was STARTED, with the next free index for that day, and create a fresh empty
# <prefix>.log. smbd is told to reopen its log with `smbcontrol all reload-config`.
# Nothing in archived/ is ever written to again, so pruning there is safe.
#
# Files in archived/ older than KEEP_DAYS are deleted. Run by samba-logroll.timer
# every CRON_LOG minutes (smb.conf kit key), so a file can overshoot the cap by up
# to CRON_LOG minutes of logging.
set -euo pipefail

CONF=${LOGROLL_CONF:-/etc/samba/logroll.conf}
# shellcheck disable=SC1090
. "$CONF"
: "${LOG_DIR:?}" "${ARCHIVE_DIR:?}" "${STATE_DIR:?}" "${SMB_SERVICE:?}" \
  "${SAMBA_PREFIX:?}" "${SAMBA_MAX_MB:?}" "${ROTATE_PREFIX:?}" "${ROTATE_MAX_MB:?}" \
  "${KEEP_DAYS:?}" "${OWNER_GROUP:?}"

SAMBA_MAX=$((SAMBA_MAX_MB * 1024 * 1024))
ROTATE_MAX=$((ROTATE_MAX_MB * 1024 * 1024))
TODAY=$(date +%Y%m%d)
shopt -s nullglob

exec 9>"${LOGROLL_LOCK:-/run/samba-logroll.lock}"
flock -n 9 || exit 0

install -d -m 0750 -o root -g root "$STATE_DIR"

mk()      { install -m 0640 -o root -g "$OWNER_GROUP" /dev/null "$1"; }
size_of() { stat -c %s "$1" 2>/dev/null || echo 0; }
rlog()    { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_DIR/$ROTATE_PREFIX.log"; }

# started_day PREFIX -> the day <prefix>.log was started (state file, mtime, or today)
started_day() {
  local s="$STATE_DIR/$1.day"
  if [[ -s $s ]]; then
    local d
    read -r d < "$s" || true
    [[ $d =~ ^[0-9]{8}$ ]] && { echo "$d"; return; }
  fi
  if [[ -f $LOG_DIR/$1.log ]]; then date -r "$LOG_DIR/$1.log" +%Y%m%d; else echo "$TODAY"; fi
}

set_started_day() { printf '%s\n' "$2" > "$STATE_DIR/$1.day"; }

# effective_day PREFIX DAY -> DAY, but re-baselined to today when the current file is
# empty: an empty file holds nothing from the older day, so filing it under that day
# (and the content written to it today) would misattribute the archive.
effective_day() {
  if (( $(size_of "$LOG_DIR/$1.log") == 0 )) && [[ $2 != "$TODAY" ]]; then
    set_started_day "$1" "$TODAY"; echo "$TODAY"
  else
    echo "$2"
  fi
}

# next_archive PREFIX DAY -> free path in archived/ for that day (not created here)
next_archive() {
  local prefix=$1 day=$2 idx=0 f n
  for f in "$ARCHIVE_DIR/$prefix-$day-"*.log; do
    n=${f##*-}; n=${n%%.*}
    [[ $n =~ ^[0-9]+$ ]] || continue
    if (( 10#$n > idx )); then idx=$((10#$n)); fi
  done
  echo "$ARCHIVE_DIR/$prefix-$day-$((idx + 1)).log"
}

# archive_stream PREFIX DAY -> moves <prefix>.log into archived/, recreates it, echoes the new path
archive_stream() {
  local prefix=$1 day=$2 dest
  dest=$(next_archive "$prefix" "$day")
  mv -- "$LOG_DIR/$prefix.log" "$dest"
  mk "$LOG_DIR/$prefix.log"
  set_started_day "$prefix" "$TODAY"
  echo "$dest"
}

# due SIZE MAX DAY -> 0 if the stream should be archived now
due() { (( $1 > 0 )) && { (( $1 >= $2 )) || [[ $3 != "$TODAY" ]]; }; }

reload_smbd() {
  systemctl is-active --quiet "$SMB_SERVICE" && command -v smbcontrol >/dev/null || return 0
  if smbcontrol all reload-config >/dev/null 2>&1; then
    rlog "smbd told to reopen its log (reload-config)"
  else
    rlog "WARN smbcontrol reload-config failed; smbd keeps writing to the previous file"
    return 1
  fi
}

# ---- rotate stream: handled first, so our own messages land in the right file ----
rot_cur="$LOG_DIR/$ROTATE_PREFIX.log"
[[ -e $rot_cur ]] || { mk "$rot_cur"; set_started_day "$ROTATE_PREFIX" "$TODAY"; }
rot_day=$(effective_day "$ROTATE_PREFIX" "$(started_day "$ROTATE_PREFIX")")
if due "$(size_of "$rot_cur")" "$ROTATE_MAX" "$rot_day"; then
  d=$(archive_stream "$ROTATE_PREFIX" "$rot_day")
  rlog "rotate log archived -> archived/$(basename "$d")"
fi

# ---- stale smbd fd: did smbd actually reopen after the last archive? -------------
LAST="$STATE_DIR/$SAMBA_PREFIX.last"
if [[ -s $LAST ]]; then
  IFS=$'\t' read -r last_size last_path < "$LAST" || true
  if [[ -n ${last_path:-} && -f $last_path ]] && (( $(size_of "$last_path") > ${last_size:-0} )); then
    rlog "WARN smbd is still writing to archived/$(basename "$last_path") - retrying reload-config"
    reload_smbd || true
    printf '%s\t%s\n' "$(size_of "$last_path")" "$last_path" > "$LAST"
  else
    rm -f -- "$LAST"
  fi
fi

# ---- samba stream ---------------------------------------------------------------
smb_cur="$LOG_DIR/$SAMBA_PREFIX.log"
if [[ -L $smb_cur ]]; then
  # old symlink layout: moving the link would leave smbd writing to the old target
  msg="WARN $SAMBA_PREFIX.log is a symlink (pre-archived layout); samba stream left untouched - migrate it first"
  rlog "$msg"; echo "samba-logroll: $msg" >&2
else
  [[ -e $smb_cur ]] || { mk "$smb_cur"; set_started_day "$SAMBA_PREFIX" "$TODAY"; rlog "created $SAMBA_PREFIX.log"; }
  smb_day=$(effective_day "$SAMBA_PREFIX" "$(started_day "$SAMBA_PREFIX")")
  if due "$(size_of "$smb_cur")" "$SAMBA_MAX" "$smb_day"; then
    dest=$(archive_stream "$SAMBA_PREFIX" "$smb_day")
    rlog "samba log archived -> archived/$(basename "$dest")"
    printf '%s\t%s\n' "$(size_of "$dest")" "$dest" > "$LAST"
    reload_smbd || true
  fi
fi

# ---- retention (archived/ only; nothing in use lives there) ---------------------
while IFS= read -r -d '' f; do
  rm -f -- "$f"
  rlog "pruned archived/$(basename "$f") (older than ${KEEP_DAYS} days)"
done < <(find "$ARCHIVE_DIR" -maxdepth 1 -type f \
           \( -name "$SAMBA_PREFIX-[0-9]*-[0-9]*.log" -o -name "$ROTATE_PREFIX-[0-9]*-[0-9]*.log" \) \
           -mtime +"$KEEP_DAYS" -print0)
