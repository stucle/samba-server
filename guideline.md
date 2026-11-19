# Guideline — samba-ubuntu-kit

Detailed reference for the kit. The short version is in [README.md](README.md).

Source: Lightsail host `maverick` (Ubuntu 24.04.4 LTS), Samba 4.19.5+dfsg-4ubuntu9.8, cloned 2026-10-30.
Target: **Ubuntu 22.04 / 24.04 only** (service `smbd`, share owner `ubuntu`, share at `/home/ubuntu/samba`). `setup.sh` refuses to run on anything else; widen the `VERSION_ID` case in it deliberately, not by accident.

## Files

| File | Purpose |
|---|---|
| `smb.conf` | Template. `setup.sh` renders it into `/etc/samba/smb.conf` (see *Kit-only keys*) |
| `samba-logroll.sh` / `.service` / `.timer` | → `/usr/local/sbin/samba-logroll` + systemd timer: current log file in `log/`, size-capped archives in `log/archived/`, see *Logging*. Replaces logrotate |
| `etc-systemd-smbd-dropin/limits.conf` | → `/etc/systemd/system/smbd.service.d/limits.conf` (caps smbd at 1G RAM) |
| `var-lib-samba-private/private.tar` | **Contains `passdb.tdb` + `secrets.tdb`** — Samba's user/password-hash DB and machine secret. Mode `600`. Treat as credential material: don't print it, don't commit it. Used for the **first install only** |
| `users-groups.txt` | Reference for the Unix accounts backing the Samba users |
| `samba-packages.txt` | Packages `setup.sh` installs with `apt-get` |
| `share-dir-perms.txt` | Ownership/mode of the home, share and log directories |
| `setup.sh` | Idempotent script that applies all of the above |

`setup.sh` also *generates* one file that is not in the kit: `/etc/samba/logroll.conf`, the roller's config, built from the kit-only keys below. Don't edit it by hand — it is rewritten on every run.

## Install

```
scp -r samba-ubuntu-kit <new-host>:~/
ssh <new-host>
sudo bash ~/samba-ubuntu-kit/setup.sh
```

Then join Tailscale and verify the cloud firewall before considering it live.

## Behaviour worth knowing

- **Idempotent.** Re-running changes nothing if nothing changed: config files are compared and only rewritten (with a `*.bak.<timestamp>` backup) when different; `smbd` is restarted only after a real change to `smb.conf` or the drop-in.
- **The kit's `smb.conf` is the source of truth.** `setup.sh` overwrites `/etc/samba/smb.conf` whenever it differs, so make config changes in the kit and re-run `setup.sh`; edits made directly in `/etc/samba/smb.conf` are lost (a `.bak` copy is kept).
- **Users are never overwritten.** `private.tar` is restored only if `/var/lib/samba/private/passdb.tdb` does not exist. Once it exists, users belong to the onboard/offboard procedure and `setup.sh` leaves the DB alone. After a restore it runs `pdbedit -L`; if this Samba version cannot read the DB the files are moved aside as `*.failed.<timestamp>` and the script stops — recreate users with `smbpasswd -a` and re-run. The kit was taken from Samba 4.19.5, which is exactly what Ubuntu 24.04 ships, so on 24.04 the restore is version-matched; on 22.04 (Samba 4.15) it may be refused — that is what the `pdbedit -L` check is for.
- **Kit-only keys in `smb.conf`.** These are not Samba parameters. `setup.sh` reads them, substitutes them into the real lines (`hosts allow`, `log file`), `/etc/samba/logroll.conf` and the timer, and strips them from the installed file:

  | Key | Default | Meaning |
  |---|---|---|
  | `HOSTS_ALLOW` | `127.0.0.1 100.64.0.0/10 fd7a:115c:a1e0::/48` | loopback + Tailscale IPv4/IPv6 |
  | `SAMBA_LOG_PREFIX` | `samba` | prefix of smbd log files |
  | `SAMBA_LOG_MAX_MB` | `10` | size cap of one smbd log file |
  | `ROTATE_LOG_PREFIX` | `rotate` | prefix of the roller's own log files |
  | `ROTATE_LOG_MAX_MB` | `10` | size cap of one roller log file |
  | `LOG_KEEP_DAYS` | `30` | days before old log files are deleted |
  | `CRON_LOG` | `120` | minutes between `samba-logroll` runs |
  | `ROLL_DAILY_AT` | `00:00` | extra daily run, `HH:MM` 24h, server time zone |

  Change them in the kit's `smb.conf`, then re-run `setup.sh`.
- **Listening interfaces.** `interfaces = lo tailscale0` + `bind interfaces only = yes`: smbd does not listen on the public NIC at all (`hosts allow` is a second layer). If `tailscale0` is not up when smbd starts, it listens on loopback only — run `sudo systemctl restart smbd` once Tailscale is up.
- **`/home/ubuntu` gets `g+x`.** Ubuntu cloud images already create it `0750 ubuntu:ubuntu`, so this is normally a no-op guard; `reader`/`groot` are in group `ubuntu` and need it to reach the share. They get traverse only, not listing.
- **AppArmor.** Ubuntu's `samba` package ships **no enabled profile for `smbd`** (the profile lives in `apparmor-profiles-extra`, which this kit does not install), so normally there is nothing to do and the share works as a plain filesystem path. `setup.sh` only **reports**: if `aa-status` lists a `/usr/sbin/smbd` profile at all — enforce *or* complain mode, the check does not distinguish them — it prints the rule you would need (`/home/ubuntu/samba/** rwk,` in `/etc/apparmor.d/local/usr.sbin.smbd`, then `apparmor_parser -r`). In complain mode the share still works and the denial is only logged, so treat the warning as "check this", not "this is broken". It never edits AppArmor policy — confining smbd is a deliberate decision, not a side effect of running this script.
- **`nmbd` is left as the package set it.** It is enabled by the `samba` package, honours the same `interfaces` / `bind interfaces only`, and so stays off the public NIC. SMB over Tailscale does not need NetBIOS name service; `setup.sh` prints a hint and you can `sudo systemctl disable --now nmbd` if you want it gone.
- **Usershares are switched off.** Debian/Ubuntu's `samba` package enables usershares (any member of group `sambashare` may publish a share with `net usershare add`, independently of `/etc/samba/smb.conf`). The kit sets `usershare allow guests = no` and `usershare max shares = 0`, so the installed `smb.conf` is the only place shares come from. The `sambashare` group still exists — the kit puts nobody in it.
- **The package's own logrotate file is left alone.** Ubuntu ships `/etc/logrotate.d/samba`, which covers `/var/log/samba/*.log` only and never looks at the share's `log/` directory, so it and `samba-logroll` do not overlap. What `setup.sh` *does* move aside is `/etc/logrotate.d/samba-custom` (the pre-roller setup from the AL2023 kit) → `/root/samba-custom.logrotate.removed.<timestamp>`.
- **Only port 445.** `smb ports = 445`: no NetBIOS-over-TCP session service on 139, which nothing in this setup needs.
- **`smbcontrol` comes from the `samba` package** on 22.04 (4.15) and 24.04 (4.19) — upstream moved it to `samba-common-bin` only in 4.20.0-2 (Ubuntu 25.04+). Both are installed, so the roller's `smbcontrol all reload-config` works on either release; worth knowing if you ever trim the package list.

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

The roller's state lives in `/var/local/lib/samba-logroll/`. `/usr/local` is the FHS location for locally-installed software and `/var/local` for its variable data, which is what `samba-logroll` is: a script this kit drops into `/usr/local/sbin`, not a packaged daemon. `/var/lib/samba` and its siblings belong to Ubuntu's `samba` package, so state put there would sit in someone else's namespace and risk being touched by package tooling. One variable, `LOGROLL_STATE_DIR` at the top of `setup.sh`, moves it if you disagree. `/var/local` itself is left exactly as Ubuntu ships it (`2775 root:staff`) — `setup.sh` creates it only if a minimal image lacks it, and touches the mode and owner of the `samba-logroll` subdirectory alone (`0750 root:root`, with the setgid bit inherited from `/var/local` cleared).

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

A higher `log level` writes much more per minute, so the roller must run more often and the cap must be larger. Change these three together (`log level` in `smb.conf`, plus `CRON_LOG` and `SAMBA_LOG_MAX_MB`), then re-run `setup.sh`:

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

- **Cloud firewall / security group**: don't open 445 publicly. Exposure is limited by `interfaces`/`hosts allow` and by the instance's own networking — check the cloud console, not this script.
- **Tailscale**: install and join the same tailnet (`sudo tailscale up`, interactive). The Tailscale ranges in `HOSTS_ALLOW` assume it.
- **apt**: `setup.sh` runs `apt-get update` only when one of its packages is missing, and installs with `DEBIAN_FRONTEND=noninteractive` + `-o Dpkg::Options::=--force-confold`, so an existing `/etc/samba/smb.conf` is never replaced by the package maintainer version behind your back (the kit installs its own afterwards). If you add the Tailscale apt repo, import its key with the documented `curl`/`tee` steps — do not disable signature checking.
- **SELinux**: n/a on Ubuntu.
