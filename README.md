# Samba build kit

Samba server (standalone, reachable over loopback + Tailscale only) for **Ubuntu 22.04 / 24.04**, cloned from host `maverick`.
Install: `sudo bash ~/samba-ubuntu-kit/setup.sh` (idempotent; can be called from any directory). Everything else — files, behaviour, logging, tuning — is in **[guideline.md](guideline.md)**.

## Users

| User | Access |
|---|---|
| `reader` | read-only |
| `groot` | read + write |

## Sharepoint

| Share | Path | Users |
|---|---|---|
| `[sharing]` | `/home/ubuntu/samba` | `reader` (read), `groot` (read/write) |

Max connections: `10` (`max connections` in `smb.conf`, applies per share). Check: `sudo smbstatus -b`. To change it, edit the kit's `smb.conf`, then `sudo bash ~/samba-ubuntu-kit/setup.sh`.

> Always edit the kit's `smb.conf` and re-run `setup.sh`; direct edits to `/etc/samba/smb.conf` are overwritten.

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
sudo bash ~/samba-ubuntu-kit/setup.sh

# remove: delete the [<name>] section from the kit's smb.conf, then
sudo bash ~/samba-ubuntu-kit/setup.sh        # the data directory is left untouched; delete it by hand if wanted
```

## Onboard / offboard a user

`setup.sh` never touches existing Samba users, so these are done by hand.

```bash
# onboard
sudo useradd -M -s /usr/sbin/nologin -G ubuntu <user>
sudo smbpasswd -a <user>
#   then add <user> to valid users (+ read list / write list) of the share in the kit's smb.conf
sudo bash ~/samba-ubuntu-kit/setup.sh

# offboard
#   first remove <user> from valid users / read list / write list in the kit's smb.conf
sudo bash ~/samba-ubuntu-kit/setup.sh
sudo smbpasswd -x <user>
sudo userdel <user>

# list Samba users
sudo pdbedit -L
```
