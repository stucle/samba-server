# Samba build kit

Samba server (standalone, reachable over loopback + Tailscale only) for **Debian/Ubuntu (apt)**, cloned from host `maverick`.
Install is two steps, **in this order** (each idempotent; callable from any directory):

```bash
sudo bash ~/samba-ubuntu-kit/install.sh    # 1) puts packages, config, drop-in, user DB on disk; does NOT restart smbd
sudo bash ~/samba-ubuntu-kit/restart.sh    # 2) daemon-reload, enable, (re)start smbd + log-roll timer
```

Running only `install.sh` leaves new config on disk while smbd still runs the old one. `restart.sh` refuses to run before `install.sh`. Everything else — files, behaviour, logging, tuning — is in **[documentation/guideline.md](documentation/guideline.md)**.

## Users

| User | Access |
|---|---|
| `reader` | read-only |
| `groot` | read + write |

## Sharepoint

| Share | Path | Users |
|---|---|---|
| `[sharing]` | `/home/ubuntu/samba` (default; `install.sh --share-user <name>` → `/home/<name>/samba`) | `reader` (read), `groot` (read/write) |

Max connections: `10` (`max connections` in `smb.conf`, applies per share). Check: `sudo smbstatus -b`. To change it, edit the kit's `smb.conf`, then run `install.sh` and `restart.sh` (see Install).

> Always edit the kit's `smb.conf` and re-run `install.sh` + `restart.sh`; direct edits to `/etc/samba/smb.conf` are overwritten.

## Manual commands — caller syntax

The add/remove sharepoint and onboard/offboard commands below are **manual commands, not scripts** (the kit has no onboard/offboard script). How to call them:

- **Caller:** a user with `sudo` (e.g. `ubuntu`), logged in on the Samba host itself, from any directory. The kit is assumed at `~/samba-ubuntu-kit/`.
- **Placeholders:** `<user>` = Unix account name, `[a-z_][a-z0-9_-]*`; `<name>` = share name (the text in `[...]`); `<dir>` = directory name under `/home/ubuntu/`.
- `sudo smbpasswd -a <user>` is interactive: it prompts twice for the new password. Don't pass the password on the command line.
- Editing the "kit's `smb.conf`" means `~/samba-ubuntu-kit/smb.conf`, not `/etc/samba/smb.conf`.

## Add / remove a sharepoint

```bash
# add: 1) create the directory
sudo install -d -m 0770 -o ubuntu -g ubuntu /home/ubuntu/<dir>
# 2) append a section to the kit's smb.conf
#    [<name>]
#       path        = /home/ubuntu/<dir>
#       valid users = reader groot
#       read list   = reader
#       write list  = groot
#       read only   = yes
#       force group = ubuntu
# 3) apply
sudo bash ~/samba-ubuntu-kit/install.sh && sudo bash ~/samba-ubuntu-kit/restart.sh

# remove: delete the [<name>] section from the kit's smb.conf, then
sudo bash ~/samba-ubuntu-kit/install.sh && sudo bash ~/samba-ubuntu-kit/restart.sh        # the data directory is left untouched; delete it by hand if wanted
```

## Onboard / offboard a user

`install.sh` never touches existing Samba users, so these are done by hand.

```bash
# onboard
sudo useradd -M -s /usr/sbin/nologin -G ubuntu <user>
sudo smbpasswd -a <user>
#   then add <user> to valid users (+ read list / write list) of the share in the kit's smb.conf
sudo bash ~/samba-ubuntu-kit/install.sh && sudo bash ~/samba-ubuntu-kit/restart.sh

# offboard
#   first remove <user> from valid users / read list / write list in the kit's smb.conf
sudo bash ~/samba-ubuntu-kit/install.sh && sudo bash ~/samba-ubuntu-kit/restart.sh
sudo smbpasswd -x <user>
sudo userdel <user>

# list Samba users
sudo pdbedit -L
```
