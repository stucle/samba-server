# Guideline — samba-build-kit

Detailed reference for the kit. The short version is in [README.md](README.md).

Source: Lightsail host `maverick` (Ubuntu 24.04.4 LTS), Samba 4.19.5+dfsg-4ubuntu9.8, cloned 2026-10-30.
Target: **Amazon Linux 2023 only** (Samba 4.17.12 from the AL2023 repo, service `smb`, share owner `ec2-user`). `setup.sh` refuses to run on anything else.

## Files

| File | Purpose |
|---|---|
| `smb.conf` | Template. `setup.sh` renders it into `/etc/samba/smb.conf` (see *Kit-only keys*) |
| `samba-logroll.sh` / `.service` / `.timer` | → `/usr/local/sbin/samba-logroll` + systemd timer: current log file in `log/`, size-capped archives in `log/archived/`, see *Logging*. Replaces logrotate |
| `etc-systemd-smb-dropin/limits.conf` | → `/etc/systemd/system/smb.service.d/limits.conf` (caps smb at 1G RAM) |
| `var-lib-samba-private/private.tar` | **Contains `passdb.tdb` + `secrets.tdb`** — Samba's user/password-hash DB and machine secret. Mode `600`. Treat as credential material: don't print it, don't commit it. Used for the **first install only** |
| `users-groups.txt` | Reference for the Unix accounts backing the Samba users |
| `samba-packages.txt` | Packages `setup.sh` installs with `dnf` |
| `share-dir-perms.txt` | Ownership/mode of the home, share and log directories |
| `setup.sh` | Idempotent script that applies all of the above |

## Install

```
scp -r samba-build-kit <new-host>:~/
ssh <new-host>
sudo bash ~/samba-build-kit/setup.sh
```

Then join Tailscale and verify the cloud firewall before considering it live.

## Behaviour worth knowing

- **Idempotent.** Re-running changes nothing if nothing changed: config files are compared and only rewritten (with a `*.bak.<timestamp>` backup) when different; `smb` is restarted only after a real change to `smb.conf` or the drop-in.
- **The kit's `smb.conf` is the source of truth.** `setup.sh` overwrites `/etc/samba/smb.conf` whenever it differs, so make config changes in the kit and re-run `setup.sh`; edits made directly in `/etc/samba/smb.conf` are lost (a `.bak` copy is kept).
- **Users are never overwritten.** `private.tar` is restored only if `/var/lib/samba/private/passdb.tdb` does not exist. Once it exists, users belong to the onboard/offboard procedure and `setup.sh` leaves the DB alone. After a restore it runs `pdbedit -L`; if this Samba version cannot read the DB (the kit is from 4.19, AL2023 has 4.17) the files are moved aside as `*.failed.<timestamp>` and the script stops — recreate users with `smbpasswd -a` and re-run.
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
- **Listening interfaces.** `interfaces = lo tailscale0` + `bind interfaces only = yes`: smbd does not listen on the public NIC at all (`hosts allow` is a second layer). If `tailscale0` is not up when smb starts, it listens on loopback only — run `sudo systemctl restart smb` once Tailscale is up.
- **`/home/ec2-user` gets `g+x`** (AL2023 default is `700`) so `reader`/`groot`, which are in group `ec2-user`, can reach the share. They get traverse only, not listing.
- **SELinux.** If not `Disabled`, the share is labelled `samba_share_t` (`semanage fcontext` + `restorecon`). Only exercised in Permissive so far; test under Enforcing before relying on it. A share added later outside `/home/ec2-user/samba` needs the same labelling: `sudo semanage fcontext -a -t samba_share_t "<path>(/.*)?" && sudo restorecon -R <path>`.

## Logging

Two streams, each with one *current* file in `/home/ec2-user/samba/log/` and its history in `/home/ec2-user/samba/log/archived/`:

```
log/samba.log                        current, written by smbd
log/rotate.log                       current, activity log of the roller itself
log/archived/samba-20261031-1.log    archived
log/archived/rotate-20261031-1.log   archived
```

The current file keeps being appended to until it reaches its MB cap, **or** until the day it was started is no longer today. `samba-logroll` then moves it into `archived/` as `<prefix>-<day it was started>-<next free index for that day>.log`, creates a fresh empty current file (`0640 root:ec2-user`) and runs `smbcontrol all reload-config` so smbd reopens it. `max log size` in the installed `smb.conf` is `0` on purpose (smbd's own rename-to-`.old` would fight with this); the cap is `SAMBA_LOG_MAX_MB`. An empty current file is never archived, so a quiet day produces no file.

Nothing in `archived/` is ever written to again, which is what makes pruning there safe — the files in use live one level up and are outside the prune scope entirely.

The day a current file was started is remembered in `/var/lib/samba-logroll/<prefix>.day` (outside the share), so a file is always archived under the day its first line belongs to, even on a busy server where mtime would say "today".

If `smbcontrol reload-config` fails, smbd keeps writing into the file that was just archived. The roller records that file and its size in `/var/lib/samba-logroll/samba.last`; on every later run it checks whether that file is still growing and, if so, logs a `WARN` and **retries the reload**. A still-growing file has a fresh mtime, so retention never deletes it out from under smbd.

The roller refuses to touch the samba stream while `log/samba.log` is still a symlink (the pre-`archived/` layout): it logs a `WARN` to `rotate.log` **and to the journal** (`systemctl status samba-logroll`) and leaves that stream alone, so migration is never done half-way behind your back. The rotate stream and retention still run.

`samba-logroll` runs every time the cron configured by `CRON_LOG` fires (minutes), **and once a day at `ROLL_DAILY_AT`** (default `00:00`; both in `samba-logroll.timer`). The 00:00 run archives yesterday's current file right away, so the new day starts with a fresh one. Consequences:

- a file can overshoot its cap by up to `CRON_LOG` minutes of logging;
- the timer fires within ~5 s of `ROLL_DAILY_AT` (`AccuracySec=5s`), so the first few seconds after midnight can still land in the previous day's file; keep `ROLL_DAILY_AT` at `00:00` (a time before midnight would just add a pointless run);
- files older than `LOG_KEEP_DAYS` are deleted (never the ones in use); no compression;
- dates use the server's time zone (UTC on AL2023).

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
- Check the actual sizes with `ls -lh /home/ec2-user/samba/log/`.

## What is NOT captured here (do manually)

- **Cloud firewall / security group**: don't open 445 publicly. Exposure is limited by `interfaces`/`hosts allow` and by the instance's own networking — check the cloud console, not this script.
- **Tailscale**: install and join the same tailnet (`sudo tailscale up`, interactive). The Tailscale ranges in `HOSTS_ALLOW` assume it.
- **dnf + Tailscale repo**: if `dnf` ever reports `repomd.xml GPG signature verification error: Bad GPG signature` for `tailscale-stable`, the repo key was never imported because dnf was run without `-y` and the prompt was auto-answered "no". Fix: `sudo dnf -y makecache` (do not disable `repo_gpgcheck`). `setup.sh` always uses `-y`.
- **AppArmor**: n/a on AL2023.
