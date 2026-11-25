# Guideline — samba-ubuntu-kit

Detailed reference for the kit. The short version is in [README.md](../README.md).

Source: Lightsail host `maverick` (Ubuntu 24.04.4 LTS), Samba 4.19.5+dfsg-4ubuntu9.8, cloned 2026-10-30.
Target: Debian/Ubuntu with `apt` (service `smbd`, share owner `ubuntu`, share at `/home/ubuntu/samba` by default; another owner via `install.sh --share-user <name>`, see *Share owner* below). The scripts do **not** check the distro or version; on a host without `apt-get`, `dpkg-query` or the `ubuntu` user they fail at the first missing piece. Tested on Ubuntu 22.04 and 24.04 only.

## Files

| File | Purpose |
|---|---|
| `documentation/guideline.md` | This file |
| `smb.conf` | Template. `install.sh` renders it into `/etc/samba/smb.conf` (see *Kit-only keys*) |
| `logroll/samba-logroll.sh` / `.service` / `.timer` | → `/usr/local/sbin/samba-logroll` + systemd timer: current log file in `log/`, size-capped archives in `log/archived/`, see *Logging*. Replaces logrotate |
| `to-copy/manifest.json` | Declares every plain file `install.sh` copies to the host — see *The manifest* below |
| `to-copy/limits.conf` | → `/etc/systemd/system/smbd.service.d/limits.conf` (caps smbd at 1G RAM) |
| `to-copy/passdb.tdb`, `to-copy/secrets.tdb` | **Samba's user/password-hash DB and machine secret.** Treat as credential material: don't print them. Restored only while the host has no Samba users |
| `manifest.py` | Validates `manifest.json` and flattens it for `install.sh` / `uninstall.sh` (needs `python3`) |
| `documentation/users-groups.txt` | Reference for the Unix accounts backing the Samba users |
| `documentation/samba-packages.txt` | Packages `install.sh` installs with `apt-get` |
| `documentation/share-dir-perms.txt` | Ownership/mode of the home, share and log directories |
| `install.sh` | Idempotent. Puts everything on disk: packages, users/groups, directories, `smb.conf`, log-roller files, drop-in, first-install user DB. **Never restarts or starts smbd**, except stopping it before the user-DB restore |
| `restart.sh` | Idempotent. Makes the on-disk state live: `daemon-reload`, `enable`, one `samba-logroll` run, log-roll timer, **restart** (or start) of `smbd`. Run after `install.sh` |

`install.sh` also *generates* one file that is not in the kit: `/etc/samba/logroll.conf`, the roller's config, built from the kit-only keys below. Don't edit it by hand — it is rewritten on every run.

## Install

```
scp -r samba-ubuntu-kit <new-host>:~/
ssh <new-host>
sudo bash ~/samba-ubuntu-kit/install.sh
sudo bash ~/samba-ubuntu-kit/restart.sh
```

The same two commands, in the same order, apply any later change (`smb.conf`, drop-in, log keys).

- **Order is mandatory.** `restart.sh` assumes `install.sh` has run: it checks that `/usr/local/sbin/samba-logroll` exists and stops with an error otherwise, before touching any service.
- **Between the two runs the host is in a half-applied state.** New files are on disk, but `smbd` still runs the old config and the old systemd limits. `install.sh` prints a reminder at the end; do not leave it at that.
- **`daemon-reload` lives in `restart.sh` and must not be dropped.** The `limits.conf` drop-in and the log-roll unit files only take effect after `systemctl daemon-reload` followed by a restart.
- **`restart.sh` always restarts `smbd`** (no "did anything change" tracking between the scripts, so no state shared between them). A restart drops open SMB connections for a moment; clients reconnect.

Then join Tailscale and verify the cloud firewall before considering it live.

## Behaviour worth knowing

- **Idempotent.** Re-running `install.sh` changes nothing if nothing changed: config files are compared and only rewritten (with a `*.bak.<timestamp>` backup) when different. `restart.sh` restarts `smbd` on every run.
- **The kit's `smb.conf` is the source of truth.** `install.sh` overwrites `/etc/samba/smb.conf` whenever it differs, so make config changes in the kit and re-run `install.sh` + `restart.sh`; edits made directly in `/etc/samba/smb.conf` are lost (a `.bak` copy is kept).
- **Users are never overwritten.** `to-copy/passdb.tdb` + `secrets.tdb` are copied only while the host has no Samba users (`passdb.tdb` absent, or `pdbedit -L` lists nobody — the empty one apt creates when it starts smbd counts as "no users"). Once users exist they belong to the onboard/offboard procedure and `install.sh` skips the pair. If `passdb.tdb` exists but `pdbedit` cannot read it, `install.sh` stops and touches nothing. When the pair is replaced no backup is made (there were no users to lose), `smbd` is stopped first, and afterwards `pdbedit -L` must succeed; if this Samba version cannot read the DB the files are moved aside as `*.failed.<timestamp>` and the script stops — recreate users with `smbpasswd -a` and re-run. The kit was taken from Samba 4.19.5 (Ubuntu 24.04). On a host with an older Samba (e.g. 22.04's 4.15) the restore may be refused — this `pdbedit -L` check, not a version gate, is what guards it.
- **Kit-only keys in `smb.conf`.** These are not Samba parameters. `install.sh` reads them, substitutes them into the real lines (`hosts allow`, `log file`), `/etc/samba/logroll.conf` and the timer, and strips them from the installed file:

  | Key | Default | Meaning |
  |---|---|---|
  | `SHARE_USER` | `ubuntu` | owner of the share: it lives in `<home of that user>/samba`, owned by user:group of that name, which is also `force group`. Override per host with `install.sh --share-user <name>` (or env `SHARE_USER`); the flag wins over this value |
  | `HOSTS_ALLOW` | `127.0.0.1 100.64.0.0/10 fd7a:115c:a1e0::/48` | loopback + Tailscale IPv4/IPv6 |
  | `SAMBA_LOG_PREFIX` | `samba` | prefix of smbd log files |
  | `SAMBA_LOG_MAX_MB` | `10` | size cap of one smbd log file |
  | `ROTATE_LOG_PREFIX` | `rotate` | prefix of the roller's own log files |
  | `ROTATE_LOG_MAX_MB` | `10` | size cap of one roller log file |
  | `LOG_KEEP_DAYS` | `30` | days before old log files are deleted |
  | `CRON_LOG` | `120` | minutes between `samba-logroll` runs |
  | `ROLL_DAILY_AT` | `00:00` | extra daily run, `HH:MM` 24h, server time zone |

  Change them in the kit's `smb.conf`, then re-run `install.sh` and `restart.sh`.
- **Listening interfaces.** `interfaces = lo` + `bind interfaces only = yes`: smbd listens on loopback only, never on the public NIC (nor `0.0.0.0`). Samba refuses point-to-point interfaces such as `tailscale0` (log: `not adding non-broadcast interface`; naming the interface, its IP or the CGNAT range in `interfaces` does not help, and `bind interfaces only = no` would open `0.0.0.0`), so the tailnet reaches smbd through `tailscale serve --bg --tcp 445 tcp://localhost:445`, which `restart.sh` runs (idempotent, persisted by tailscaled; `uninstall.sh` removes it with `--tcp 445 off`). Consequences: smbd sees every client as `127.0.0.1`, so `hosts allow` no longer tells tailnet machines apart — who may connect is decided by the **tailnet ACLs**. If Tailscale is missing or down, `restart.sh` only warns; re-run it once Tailscale is up.
- **Share owner (`SHARE_USER`).** Default `ubuntu` (share `/home/ubuntu/samba`). `sudo bash install.sh --share-user vikki` puts the share in `/home/vikki/samba` instead, with `force group = vikki`; `smb.conf`, `logroll.conf` and the directories are all rendered from that one value. The user must exist, have a home `/home/<name>` and a group of the same name. `reader`/`groot` are added to that group, so they can reach everything that group can reach (including `r-x` on the owner's home). Memberships of an earlier owner's group are not removed on re-install. `uninstall.sh` reads the share path back from `/etc/samba/logroll.conf`.
- **The owner's home gets `g+x`.** Ubuntu cloud images already create `/home/ubuntu` `0750 ubuntu:ubuntu`, so this is normally a no-op guard; `reader`/`groot` are in the share group and need it to reach the share.
- **AppArmor.** Ubuntu's `samba` package ships **no enabled profile for `smbd`** (the profile lives in `apparmor-profiles-extra`, which this kit does not install), so normally there is nothing to do and the share works as a plain filesystem path. `install.sh` only **reports**: if `aa-status` lists a `/usr/sbin/smbd` profile at all — enforce *or* complain mode, the check does not distinguish them — it prints the rule you would need (`/home/ubuntu/samba/** rwk,` in `/etc/apparmor.d/local/usr.sbin.smbd`, then `apparmor_parser -r`). In complain mode the share still works and the denial is only logged, so treat the warning as "check this", not "this is broken". It never edits AppArmor policy — confining smbd is a deliberate decision, not a side effect of running this script.
- **`nmbd` is left as the package set it.** It is enabled by the `samba` package, honours the same `interfaces` / `bind interfaces only` (loopback only here). SMB over Tailscale does not need NetBIOS name service; `restart.sh` prints a hint and you can `sudo systemctl disable --now nmbd` if you want it gone.
- **Usershares are switched off.** Debian/Ubuntu's `samba` package enables usershares (any member of group `sambashare` may publish a share with `net usershare add`, independently of `/etc/samba/smb.conf`). The kit sets `usershare allow guests = no` and `usershare max shares = 0`, so the installed `smb.conf` is the only place shares come from. The `sambashare` group still exists — the kit puts nobody in it.
- **The package's own logrotate file is left alone.** Ubuntu ships `/etc/logrotate.d/samba`, which covers `/var/log/samba/*.log` only and never looks at the share's `log/` directory, so it and `samba-logroll` do not overlap. What `install.sh` *does* move aside is `/etc/logrotate.d/samba-custom` (the pre-roller setup from the AL2023 kit) → `/root/samba-custom.logrotate.removed.<timestamp>`.
- **Only port 445.** `smb ports = 445`: no NetBIOS-over-TCP session service on 139, which nothing in this setup needs.
- **`smbcontrol` comes from the `samba` package** on 22.04 (4.15) and 24.04 (4.19) — upstream moved it to `samba-common-bin` only in 4.20.0-2 (Ubuntu 25.04+). Both are installed, so the roller's `smbcontrol all reload-config` works on either release; worth knowing if you ever trim the package list.

## The manifest

`to-copy/manifest.json` is data, not code: an array of objects, one per file. `install.sh` validates the whole file first (via `manifest.py`) and copies nothing if anything is wrong. JSON has no comments, so the fields are documented here.

| Field | Default | Meaning |
|---|---|---|
| `fileName` | required | name at the destination |
| `sourcePath` | required | path in the kit, relative to the kit root; must be a regular file inside the kit |
| `destination` | required | absolute directory on the host; final path is `destination/fileName` |
| `mode` / `owner` / `dirMode` | `0644` / `root:root` / `0755` | file mode, `user:group`, and mode of `destination` if it has to be created |
| `overwrite` | `ifChanged` | `ifChanged` = replace only if content differs; `always`; `ifAbsent` = never touch an existing file |
| `backup` | `true` | keep the old file as `<dest>.bak.<timestamp>` before replacing |
| `guard` | none | named check run before the entry; false = entry skipped (not an error). Whitelist: `samba-passdb-no-users` |
| `verify` | none | named check run after copying; failing = files moved aside, install stops. Whitelist: `samba-passdb-readable` |
| `group` | none | entries sharing a `group` are one unit: one guard evaluation, one verify (must agree on both) |
| `uninstall` | `remove` | `remove` = delete if still identical to the kit's copy; `keep`; `purge` = delete only with `uninstall.sh --purge` |

Unknown keys, `..` in paths, a relative `destination`, a `/` in `fileName`, duplicate targets, and unknown guard/verify names are all rejected. Anyone who can edit the manifest chooses what root writes where, so review changes to it like code. There is no `restart` field: `restart.sh` always restarts `smbd`.

## Logging

Two streams, each with one *current* file in `/home/ubuntu/samba/log/` and its history in `/home/ubuntu/samba/log/archived/`:

```
log/samba.log                        current, written by smbd
log/rotate.log                       current, activity log of the roller itself
log/archived/samba-20261031-1.log    archived
log/archived/rotate-20261031-1.log   archived
```

The current file keeps being appended to until it reaches its MB cap, **or** until the day it was started is no longer today. `samba-logroll` then moves it into `archived/` as `<prefix>-<day it was started>-<next free index for that day>.log`, creates a fresh empty current file (`0640 root:ubuntu`) and runs `smbcontrol all reload-config` so smbd reopens it. `max log size` in the installed `smb.conf` is `0` on purpose (smbd's own rename-to-`.old` would fight with this); the cap is `SAMBA_LOG_MAX_MB`. An empty current file is never archived, so a quiet day produces no file.

Nothing in `archived/` is ever written to again, which is what makes pruning there safe — the files in use live one level up and are outside the prune scope entirely.

The roller's state lives in `/var/local/lib/samba-logroll/`. `/usr/local` is the FHS location for locally-installed software and `/var/local` for its variable data, which is what `samba-logroll` is: a script this kit drops into `/usr/local/sbin`, not a packaged daemon. `/var/lib/samba` and its siblings belong to Ubuntu's `samba` package, so state put there would sit in someone else's namespace and risk being touched by package tooling. One variable, `LOGROLL_STATE_DIR` at the top of `install.sh`, moves it if you disagree. `/var/local` itself is left exactly as Ubuntu ships it (`2775 root:staff`) — `install.sh` creates it only if a minimal image lacks it, and touches the mode and owner of the `samba-logroll` subdirectory alone (`0750 root:root`, with the setgid bit inherited from `/var/local` cleared).

The day a current file was started is remembered in `/var/local/lib/samba-logroll/<prefix>.day` (outside the share, so SMB clients cannot touch it), so a file is always archived under the day its first line belongs to, even on a busy server where mtime would say "today".

If `smbcontrol reload-config` fails, smbd keeps writing into the file that was just archived. The roller records that file and its size in `/var/local/lib/samba-logroll/samba.last`; on every later run it checks whether that file is still growing and, if so, logs a `WARN` and **retries the reload**. A still-growing file has a fresh mtime, so retention never deletes it out from under smbd.

The roller refuses to touch the samba stream while `log/samba.log` is still a symlink (the pre-`archived/` layout): it logs a `WARN` to `rotate.log` **and to the journal** (`systemctl status samba-logroll`) and leaves that stream alone, so migration is never done half-way behind your back. The rotate stream and retention still run.

`samba-logroll` runs every time the cron configured by `CRON_LOG` fires (minutes), **and once a day at `ROLL_DAILY_AT`** (default `00:00`; both in `samba-logroll.timer`). The 00:00 run archives yesterday's current file right away, so the new day starts with a fresh one. Consequences:

- a file can overshoot its cap by up to `CRON_LOG` minutes of logging;
- the timer fires within ~5 s of `ROLL_DAILY_AT` (`AccuracySec=5s`), so the first few seconds after midnight can still land in the previous day's file; keep `ROLL_DAILY_AT` at `00:00` (a time before midnight would just add a pointless run);
- files older than `LOG_KEEP_DAYS` are deleted (never the ones in use); no compression;
- dates use the server's time zone (UTC on Ubuntu cloud images);
- the `OnCalendar` run is `Persistent=true`, so a daily run missed while the instance was stopped is made up at the next boot.

### Tuning cron, size and log level

A higher `log level` writes much more per minute, so the roller must run more often and the cap must be larger. Change these three together (`log level` in `smb.conf`, plus `CRON_LOG` and `SAMBA_LOG_MAX_MB`), then re-run `install.sh` and `restart.sh`:

| `log level` | `CRON_LOG` | `SAMBA_LOG_MAX_MB` |
|---|---|---|
| 1 (default) | 120 (2 h) | 10 |
| 2 | 90 | 15 |
| 3 | 60 | 20 |
| 4 | 45 | 25 |
| 5 | 30 | 30 |
| 6 | 25 | 35 |
| 7 | 20 | 40 |
| 8 | 15 | 45 |
| 9 | 10 | 50 |
| 10 | 5 | 100 |

- `ROTATE_LOG_MAX_MB` can stay at 10 at every level: the roller's own log only records events and stays tiny.
- These are starting points, not measurements. Levels 8–10 are very verbose; if a file regularly overshoots its cap, lower `CRON_LOG` or raise the cap. Don't leave a high level on longer than needed.
- Check the actual sizes with `ls -lh /home/ubuntu/samba/log/`.

## What is NOT captured here (do manually)

- **Cloud firewall / security group**: don't open 445 publicly. smbd itself only listens on loopback; exposure is `tailscale serve` + the tailnet ACLs — check the cloud console, not this script.
- **Tailscale**: install and join the same tailnet (`sudo tailscale up`, interactive). `restart.sh` publishes `:445` to it with `tailscale serve`. `HOSTS_ALLOW` still lists the Tailscale ranges but, behind `serve`, only `127.0.0.1` ever matches.
- **apt**: `install.sh` runs `apt-get update` only when one of its packages is missing, and installs with `DEBIAN_FRONTEND=noninteractive` + `-o Dpkg::Options::=--force-confold`, so an existing `/etc/samba/smb.conf` is never replaced by the package maintainer version behind your back (the kit installs its own afterwards). If you add the Tailscale apt repo, import its key with the documented `curl`/`tee` steps — do not disable signature checking.
- **SELinux**: n/a on Ubuntu.
