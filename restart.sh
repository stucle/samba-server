#!/usr/bin/env bash
# Makes what install.sh put on disk live: daemon-reload, enable, one log-roll run, timer, (re)start smbd.
# Run as root (sudo) AFTER install.sh; safe to re-run. smbd is restarted on every run (a brief disconnect for SMB clients), so no state has to be shared with install.sh.
set -euo pipefail
cd "$(dirname "$0")"

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN:  $*" >&2; }

[[ $EUID -eq 0 ]] || die "run as root: sudo bash $0"

SVC=smbd
# install.sh must have run first: these are what it creates
for f in /usr/local/sbin/samba-logroll /etc/samba/logroll.conf /etc/samba/smb.conf \
         /etc/systemd/system/samba-logroll.service /etc/systemd/system/samba-logroll.timer; do
  [[ -e $f ]] || die "$f is missing - run install.sh first"
done
systemctl cat "$SVC" >/dev/null 2>&1 || die "$SVC unit not found - run install.sh first"

echo "== enable + (re)start =="
# must come first: the drop-in (limits.conf) and the log-roll units only take effect after a reload
systemctl daemon-reload
systemctl enable "$SVC"
/usr/local/sbin/samba-logroll        # creates log/<prefix>.log before smbd starts
systemctl enable --now samba-logroll.timer
systemctl restart samba-logroll.timer
echo "  samba-logroll.timer restarted"
if systemctl is-active --quiet "$SVC"; then systemctl restart "$SVC"; echo "  restarted $SVC"
else systemctl start "$SVC"; echo "  started $SVC"; fi

echo "== tailscale serve (tailnet :445 -> smbd on loopback) =="
# smbd listens on loopback only (Samba never binds a point-to-point interface like tailscale0, see guideline).
# tailscaled accepts SMB on the tailnet address and forwards it to localhost:445. Idempotent; the config persists in tailscaled's state.
if ! command -v tailscale >/dev/null 2>&1; then
  warn "tailscale is not installed - smbd is reachable on this host only (loopback). Install + join the tailnet, then re-run restart.sh"
elif ! tailscale ip -4 >/dev/null 2>&1; then
  warn "tailscale is installed but not connected (sudo tailscale up) - smbd is reachable on this host only. Re-run restart.sh once it is up"
elif timeout 60 tailscale serve --bg --tcp 445 tcp://localhost:445 >/dev/null 2>&1; then
  echo "  tailnet $(tailscale ip -4 | head -1):445 -> localhost:445"
else
  warn "'tailscale serve' failed (needs root/operator, and Serve enabled for the tailnet). Run it by hand: sudo tailscale serve --bg --tcp 445 tcp://localhost:445"
fi
systemctl is-enabled --quiet nmbd 2>/dev/null && warn "nmbd is enabled (NetBIOS name service, as the samba package set it). It honours the same 'interfaces'/'bind interfaces only' (loopback only here). Not needed by SMB over Tailscale: sudo systemctl disable --now nmbd"
testparm -s 2>/dev/null | sed -n '/^\[global\]/,/^$/p' | grep -E 'hosts allow|interfaces|bind interfaces|log file|max log size' || true

cat <<'EOF'

Done. Still manual:
  1. Tailscale installed + joined to the tailnet (sudo tailscale up); restart.sh then publishes :445 with 'tailscale serve'. Access is limited by the tailnet ACLs (smbd sees every client as 127.0.0.1).
  2. Check the cloud firewall / security group - do not expose port 445 publicly.
  3. Verify: smbclient -L localhost -U reader
EOF
