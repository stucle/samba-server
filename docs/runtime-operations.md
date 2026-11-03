# Runtime operations: `smbctl`

Adding and removing users, creating sharepoints, granting and revoking access — **no restart, no dropped clients**. This is the bottom layer; the [Admin API](admin-api.md) is only an HTTP wrapper around exactly these commands.

```bash
docker exec smb-pod smbctl --help
```

## Model: every subdirectory of the share root is a sharepoint

`compose.yaml` mounts **one parent directory** (`SHARE_HOST_PATH_1st` → `SHARE_CONTAINER_PATH_1st`, by default `/Volumes/RAMDisk/SMB` → `/shares/onpremise`). Each subdirectory inside it is its own sharepoint with its own share block in `smb.conf`.

The reason: Docker **cannot add a bind mount to a running container**. If every sharepoint were its own mount, creating one would mean a `--force-recreate`, i.e. dropping every client. With the parent already mounted, creating a sharepoint is just `mkdir` plus a config block plus `reload-config`.

The consequence: a new sharepoint **must** live inside that share root. A root with a different host path (OneDrive, say) still requires a `SHARE_*_<nth>` block in `config.env`, a hand-written bind mount in `compose.yaml`, and one recreate — see [adding a share](configuration.md#adding-a-share).

## Access model: groups, not user lists

Each sharepoint `X` gets two Unix groups, `sp_X_r` and `sp_X_w`, and its share block references the groups instead of listing users:

```ini
[X]
   valid users = @sp_X_r @sp_X_w
   read list   = @sp_X_r
   write list  = @sp_X_w
```

Because membership is evaluated **per connection**, granting and revoking is only adding or removing a user from a group — **no `smb.conf` change, and not even a `reload-config`**.

`read list` is mandatory; `write list` alone is not enough. `write list` only **adds** write permission, it blocks nobody, so without `read list` a user in `sp_X_r` could still write (the share has `read only = no`).

## Commands

| Command | What it does | Reload? |
|---|---|---|
| `smbctl onboard <user> <password> [group]` | `adduser` (no-login shell) + `smbpasswd -a -e`, writes `accounts.tsv` | No |
| `smbctl offboard <user>` | `smbpasswd -d` → cut live sessions → `smbpasswd -x` → `deluser` → drop the `accounts.tsv` line | No |
| `smbctl sharepoint-create <name>` | `mkdir` inside the container + two groups + a block in `dynamic.conf` + `reload-config` | Yes (automatic) |
| `smbctl grant <user> <share> r\|rw` | `r` = read only (and **removes** write if present), `rw` = read and write | No |
| `smbctl revoke <user> <share> [w\|all]` | `w` (default) = drop write, **keep read**; `all` = drop both | No |
| `smbctl state-dump` | print `dynamic.conf` + `accounts.tsv` (used by `./smb.sh state show`) | — |

A full round trip:

```bash
docker exec smb-pod smbctl sharepoint-create alpha
docker exec smb-pod smbctl onboard alice "alice's password"
docker exec smb-pod smbctl grant alice alpha r        # can read, writes get ACCESS_DENIED
docker exec smb-pod smbctl grant alice alpha rw       # can write
docker exec smb-pod smbctl revoke alice alpha         # loses write, keeps read
docker exec smb-pod smbctl revoke alice alpha all     # loses read too
docker exec smb-pod smbctl offboard alice
```

### Things to know before using it

- **Names are validated strictly:** `^[a-z0-9_-]{1,32}$` (26 characters for sharepoints, so that `sp_<name>_r` still fits in 32). Names go straight into `smb.conf`, `adduser` and `addgroup`, so `a b`, `a;id`, `../etc` and `-x` are all refused **before** reaching any of them. The check lives in `smbctl` itself, not only in the API layer, because `smbctl` is also run by hand.
- **`offboard` cuts sessions by IP**, with `smbcontrol kill-client-ip`: other sessions **from that same address** are dropped too (clients reconnect). Disabling an account only blocks the *next* authentication, so without this an open session would keep working.
- **`SMB_READ_USER`/`SMB_WRITE_USER` cannot be onboarded or offboarded**: they are base accounts owned by `config.env`, and `smbctl` refuses outright.
- **`mkdir` must run inside the container.** Creating a directory through the `smbclient` CLI produces mode `0000` on the host even with a correct `directory mask` — a client CLI quirk (see below). `smbctl` always does a server-side `mkdir`.
- **One mutex for the whole state directory** (`$SMB_STATE_DIR/.lock`, created with `mkdir`, which is atomic). Two commands running in parallel cannot clobber each other's state; if a process dies midway, remove the `.lock` directory by hand.
- Raise `SMB_CONCURRENT_CONNECTIONS` in `config.env` as you add users or sharepoints (`max smbd processes` is that value plus 2, currently 22) — changing it **requires** `--force-recreate`.

### Measuring write access: use a file, not `mkdir`

Verified 2026-11-03: `mkdir` through the `smbclient` CLI is **not** a reliable test of write permission. The directory **is created**, but with mode `d---------` (0000), and the client's next operation on it fails — so `smbclient` reports `NT_STATUS_ACCESS_DENIED` for an operation that actually succeeded. Running it again reveals the truth as `NT_STATUS_OBJECT_NAME_COLLISION`.

Test write access with a file instead:

```bash
docker exec smb-pod sh -c "smbclient //127.0.0.1/alpha -U alice%<pw> -c 'put /etc/hostname probe.txt'"
```

Files are created correctly (`-rw-rw-r--`, per `create mask`). Finder and Windows Explorer create directories correctly too; only the `smbclient` CLI shows the quirk.

## State: what survives a restart and what does not

| Thing | Lives in | Survives `--force-recreate`? |
|---|---|---|
| Share blocks created at runtime | `$SMB_STATE_DIR/dynamic.conf`, volume `samba_core` | Yes |
| Users + group membership | `$SMB_STATE_DIR/accounts.tsv`, volume `samba_core` | Yes (the entrypoint recreates the Unix accounts from this file) |
| SMB passwords | `passdb.tdb`, volume `samba_private` | Yes |
| Unix accounts in `/etc/passwd`, `/etc/group` | Container layer | **No** — which is exactly why `accounts.tsv` exists |
| Data inside a sharepoint | Bind mount on the host | Yes |

`entrypoint.sh` renders `smb.conf` from `config.env` and ends it with `include = $SMB_STATE_DIR/dynamic.conf`. That `include` line is the **last line and outside `[global]`**: `include` splices the file's content in at that exact point (like C's `#include`), so the line's position decides which section the content belongs to. Samba's `include` does **not** glob — exactly one file.

Verified 2026-11-03: `testparm -s` prints the `include` line **inside the last section** (`[cloud]`), because that is still the section context when the line is reached. That turns into a real constraint: `dynamic.conf` **must** start with a section header `[name]`; a bare directive at the top of that file would silently become a directive of `[cloud]`. `smbctl` always writes blocks as `\n[name]\n   ...`, which satisfies it.

Also verified: changes to `dynamic.conf` take effect **without a restart** — a new share shows up on the very next connection, because Samba compares the mtime of the included file too, not just of `smb.conf`. `smbcontrol all reload-config` (which `smbctl` calls anyway) does not restart `smbd`, so connected clients are never dropped.

`smbctl` writes `dynamic.conf` atomically: it writes `dynamic.conf.tmp`, builds a draft `smb.conf` whose `include` points at that temp file, runs `testparm` on the draft, and **only `mv`s on success**. So `reload-config` can never read a half-written file (`mv` within one filesystem is atomic), and errors are reported to the caller immediately rather than at the next restart.

### Where `testparm` fails — and where it does not (measured 2026-11-03)

`testparm` is **not** a general validator. It exits non-zero for only two classes:

| Content | `testparm` | Samba at runtime |
|---|---|---|
| Bad value for a known parameter (`read only = maybe`) | **exit 1** (`value is not boolean!`) | `smbd` cannot load the config |
| Structurally broken section header (`[unclosed`) | **exit 1** (`Error loading services`) | `smbd` cannot load the config |
| A junk line with no `=` (`this is not valid samba config`) | exit 0, **no warning at all** | Silently ignored |
| A parameter without `=` inside a section | exit 0 + `WARNING: No path in service ...` | Share is made unavailable |
| A duplicate section name | exit 0 | The later declaration merges into the earlier one |

So `testparm` catches exactly **the two classes that stop `smbd` from starting** — which is all the guard needs — while the remaining ones Samba itself also just ignores.

Because that guard is narrow, `sharepoint-create` additionally **asserts its own postcondition**: after building the draft it asks `testparm -s --section-name <name> --parameter-name path` and only `mv`s when the answer equals the directory it just created. Without that step, a block that is broken in an "exit 0 but useless" way would be committed with nobody noticing.

Accepted consequences:

- **Hand-editing `dynamic.conf` into garbage only prevents the container from starting for the two classes above**; for the rest it starts fine and only that share is unusable. `entrypoint.sh` keeps its single `die`, matching the behaviour of garbage in `config.env`.
- **A `sharepoint-create` that fails at the commit step still leaves the directory and the two groups behind** (they are created before the config is written, since `testparm` does not check whether a path exists). They are inert and every step is idempotent: fix the cause and re-run the same command.

### `accounts.tsv`

Tab-separated; blank lines and `#` lines are ignored:

```
# user	groups
alice	sp_alpha_r,sp_beta_w
bob	sp_alpha_w
```

- **No passwords.** `passdb.tdb` holds those; if a user appears in `accounts.tsv` but not in `pdbedit -L`, the entrypoint only warns (state drift) and does not set a password.
- **No UID column.** Every share has `force user = $SMB_WRITE_USER`, so files on the host always belong to `groot` no matter which SMB user wrote them — a runtime user's UID never reaches the host filesystem. `adduser` picks one.
- A malformed line, or a name failing the regex, is warned about and skipped — it does **not** fail the container. One junk line must not keep the whole server offline.

### Backup and seed

The volume cannot be read directly from the host, so `smb.sh` has its own subcommand:

```bash
./smb.sh state show            # cat dynamic.conf + accounts.tsv
./smb.sh state export ./backup # docker cp out to the host — run before every `down -v`
./smb.sh state import ./backup # docker cp in + smbcontrol reload-config
```

`docker cp` into a **running** container writes straight through to the volume, but Samba does not know about it — `import` runs `reload-config` afterwards.

Seeding before the container exists (empty volume):

```bash
docker run --rm -v samba_core:/state -v "$PWD/seed":/seed:ro alpine cp -a /seed/. /state/
```

The volume's real name is `samba_core`, with no project prefix, because `compose.yaml` declares an explicit `name:`. Without it, `COMPOSE_PROJECT_NAME` would make the real name `test_samba_core`, and the `docker run -v samba_core:...` above would **silently create a different, empty volume** instead of failing.
