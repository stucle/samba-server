# Configuration reference

## Why everything goes through `smb.sh`

Compose only reads a file named `.env` to substitute `${...}` in `compose.yaml`; `env_file:` merely injects variables inside the container. That is why `smb.sh` runs `docker compose --env-file config.env`. To type `docker compose` directly, symlink it: `ln -s config.env .env`.

Every variable in `compose.yaml` is written `${VAR:?}`, so a missing one fails Compose immediately instead of defaulting silently.

`smb.sh` also adds one subcommand that is not Compose's: `./smb.sh state {export <dir>|import <dir>|show}`, to copy runtime state in and out of the `samba_core` volume — see [backup and seed](runtime-operations.md#backup-and-seed).

## `config.env` and `secrets.env`

Two files, two levels of care:

| File | Contents | Read by |
|---|---|---|
| `config.env` | Everything that is not a password: image, ports, paths, limits, shares, `SMB_STATE_DIR`, `ADMIN_API_PORT` | `smb.sh` via `--env-file` (to interpolate `${VAR}` in `compose.yaml`) **and** the services' `env_file:` |
| `secrets.env` | Credentials only: `SMB_READ_PASSWORD`, `SMB_WRITE_PASSWORD`, `ADMIN_API_USER`, `ADMIN_API_PASSWORD` | **Only** the services' `env_file:` |

The split is clean because `compose.yaml` **interpolates no password** — they are read from the environment at runtime by `entrypoint.sh` and the admin service. So `smb.sh` does **not** need to pass `secrets.env` to `--env-file`, and `.dockerignore` (`*` + `!entrypoint.sh` + `!smbctl`) keeps both files out of the build context automatically.

Keep both at `chmod 600`. If the files are ever split further by category (`logging.env`, `network.env`, …), `smb.sh` **must** be changed at the same time: it reads `SMB_LOG_HOST_PATH` straight out of `config.env` to pick the log overlay, so moving that variable elsewhere makes `smb.sh` silently choose the wrong overlay with no error.

## Volumes

| Volume | Mounted at | Holds | Removed by |
|---|---|---|---|
| `samba_private` | `/var/lib/samba/private` | `passdb.tdb`, `secrets.tdb` (SMB passwords) | `docker compose down -v` |
| `samba_core` | `$SMB_STATE_DIR` (`/var/lib/samba/state`) | `dynamic.conf`, `accounts.tsv` (sharepoints and users created at runtime) | `docker compose down -v` |
| `samba_log` | `$SMB_LOG_DIR` | `smbd` logs, only in the fallback scenario — see [Log](#log) | `docker compose down -v` |

All three declare an explicit `name:` in `compose.yaml`. Without it, `COMPOSE_PROJECT_NAME` would add a prefix (`test_samba_core`), and a command like `docker run -v samba_core:/state ...` (used to seed state) would **silently create a different, empty volume** instead of failing. The rule: the name in compose equals the name in the `docker` CLI.

A consequence worth knowing: because the volumes are explicitly named, they **belong to no project** — changing `COMPOSE_PROJECT_NAME` does not create new volumes, and a new stack reuses the same `samba_private`/`samba_core`. That is what we want here (it preserves `passdb.tdb` and the state), but it also means two projects are **not** isolated from each other — never run two stacks against the same volumes at once.

`COMPOSE_PROJECT_NAME` is currently `test`, not `on-premise`: the container that used to run (now stopped and renamed `original-smb`) still carries the labels `project=on-premise, service=samba`, and **Compose identifies containers by label, not by name** — under the same project name, `up` would treat it as the `samba` service's container and delete it to create a new one. Under a different project name it is left alone, as a rollback point.

Back `samba_core` up before every `down -v`: `./smb.sh state export <dir>`.

## Image and entrypoint

The container does not run the upstream image directly. `Dockerfile` takes `SMB_BASE_IMAGE` as its base and copies `entrypoint.sh` to `/usr/local/bin/entrypoint.sh`, producing the local image `SMB_IMAGE` (`onpremise/samba:4.23.8`) — that is what Compose actually runs.

`SMB_BASE_IMAGE` is pinned by digest: `dockurr/samba:4.23.8@sha256:9e4dd0594f2f023c48b752519be2846ae193e75b7ef462c037435eac4b835dc2`. A floating tag like `4.23` follows the branch's latest patch, but pinning by digest prevents the image from changing behind the tag. To take a new patch, get the new digest with `docker manifest inspect dockurr/samba:<new tag>` and update `SMB_BASE_IMAGE` (and `SMB_IMAGE`, to keep the version aligned).

The stock entrypoint is replaced because it runs `smbd --debug-stdout`, which makes Samba ignore `log file` so logs never reach the log mount (see [Log](#log)), and because it supports only one share via environment variables. The image's `USER`, `PASS`, `NAME` and `RW` variables are unused.

Why bake it into the image instead of bind-mounting `entrypoint.sh` as before: a bind mount is re-established on **every** `docker start`, so the host file must exist at that exact path at all times — losing the file means the container cannot start again (including the automatic start after a reboot under `restart: unless-stopped`). Baked in, the entrypoint travels with the image and depends on no host file. The trade-off is that editing `entrypoint.sh` requires a rebuild — `smb.sh` appends `--build` to `up`, so that is automatic, and the build is cached, so an unchanged file costs almost nothing.

`smbctl` (the runtime admin CLI, see [runtime operations](runtime-operations.md)) is baked into the same image for the same reason: `docker exec smb-pod smbctl ...` must not depend on a host file.

`.dockerignore` narrows the build context to `entrypoint.sh` and `smbctl`, so `config.env`/`secrets.env` (which hold passwords) are never sent to the Docker daemon or baked into a layer.

The second image, `ADMIN_IMAGE` (`onpremise/smb-admin`), is built from `./admin` (multi-stage Go → non-root Alpine). It has its own build context, so the root `.dockerignore` does not apply to it.

The base image declares `VOLUME /shared`, so Docker also creates an empty anonymous volume. It is unused and can be ignored.

To take a new patch: get the new digest (above), update `SMB_BASE_IMAGE` and `SMB_IMAGE` in `config.env`, then `./smb.sh build --pull && ./smb.sh up -d --force-recreate`.

## Connections

| Variable | Samba parameter | Meaning |
|---|---|---|
| `SMB_CONCURRENT_CONNECTIONS` | `max smbd processes` | Concurrent clients server-wide. The entrypoint adds 2 for `smbd-notifyd` and `smbd-cleanupd` (currently `20 + 2 = 22`). **Raise it as you add users or sharepoints** — every connection is one `smbd` process. Changing it needs `./smb.sh up -d --force-recreate` |
| `SMB_MAX_CONNECTIONS` | `max connections` | Default limit per share. Beyond it, clients get `NT_STATUS_INSUFFICIENT_RESOURCES` |
| `SHARE_MAX_CONNECTIONS_<nth>` | `max connections` | Overrides the limit for one share |
| `SMB_DEADTIME` | `deadtime` | Idle minutes before a session is dropped |

## Shares

| Variable | Meaning |
|---|---|
| `SHARE_NAME_<nth>` | Share name — the "logical path" the client sees |
| `SHARE_HOST_PATH_<nth>` | Directory on the host |
| `SHARE_CONTAINER_PATH_<nth>` | Mount path inside the container |
| `SHARE_MOUNT_READ_ONLY_<nth>` | Read-only at the Docker layer |
| `SHARE_VALID_USERS_<nth>` | Who may enter the share |
| `SHARE_READ_ONLY_<nth>`, `SHARE_WRITE_LIST_<nth>` | Write permission at the Samba layer |
| `SHARE_READ_LIST_<nth>` | Users restricted to reading, even on a writable share. Required for `readonly` to stay read-only, because `write list` only **adds** write permission — it blocks nobody |
| `SHARE_FORCE_USER_<nth>` | The user Samba acts as on the filesystem |
| `SHARE_CREATE_MASK_<nth>`, `SHARE_DIRECTORY_MASK_<nth>` | Permissions for new files and directories |
| `SHARE_VETO_FILES_<nth>` | Files that are hidden and cannot be created |

### Static shares vs. runtime sharepoints

`SHARE_*_<nth>` is only for **roots** that need different host paths (`onpremise` → RAM disk, `cloud` → OneDrive): each root is a bind mount, and Docker cannot add a bind mount to a running container.

Inside the first root, **every subdirectory is a sharepoint**, creatable at runtime with `smbctl sharepoint-create` — no recreate, no dropped clients. Their share blocks live in `dynamic.conf` (volume `samba_core`), which is `include`d at the end of `smb.conf`, and access runs through the groups `sp_<name>_r` / `sp_<name>_w` rather than a list of users. Details: [runtime operations](runtime-operations.md).

### UID/GID

`SMB_UID`/`SMB_GID` must match the host user running Docker (`id -u` / `id -g`), because the `groot` account inside the container acts under that UID/GID against the bind mounts.

Note that `SMB_GID=20` resolves to the pre-existing group **`dialout`** on Alpine (not `staff` as on macOS), so the generated `smb.conf` contains `force group = dialout`. Harmless — what matters is the numeric GID, not the name — but do not be surprised to see `dialout` in `testparm` output or in a share block generated by `smbctl`.

## macOS metadata (xattr)

By default `streams_xattr` stores Finder metadata in extended attributes. If the host directory does not support xattrs (Finder errors while copying), change `config.env`:

```
SMB_VFS_OBJECTS=catia fruit
SMB_EA_SUPPORT=no
SMB_FRUIT_METADATA=netatalk
```

## Adding a share

Only needed when the new share **points at a different host path**. If it lives inside the already-mounted share root (`SHARE_HOST_PATH_1st`), use `smbctl sharepoint-create` instead — no recreate, no dropped clients.

1. Add a `SHARE_*_3rd` block to `config.env`.
2. Add the matching bind mount to `compose.yaml` by hand. Compose cannot loop over numbered variables.
3. Run `./smb.sh up -d --force-recreate`.

## Log

Logs are written per client, named `log.<machine>`. Where they land depends on one of three scenarios that `smb.sh` resolves on every run — `compose.yaml` declares no log mount, and `smb.sh` adds one of two overlays (`-f compose.yaml -f <overlay>`):

| Scenario | Condition | Overlay | Log location |
|---|---|---|---|
| 1. Fallback, nothing configured | `SMB_LOG_HOST_PATH` is empty, or `mkdir -p`/writing there fails | `compose.log-volume.yaml` | Named volume `SMB_LOG_VOLUME` (default `samba_log`) |
| 2. Normal bind mount | `SMB_LOG_HOST_PATH` is set and creatable/writable | `compose.log-bind.yaml` | Directly on the host at `SMB_LOG_HOST_PATH` |
| 3. Fallback, bind failed at runtime | Scenario 2 was chosen but `docker compose up` with `compose.log-bind.yaml` failed (e.g. the RAM disk is not mounted) | Retries once with `compose.log-volume.yaml` | Named volume `SMB_LOG_VOLUME` |

Scenario 3 applies only to `up`; other subcommands (`logs`, `ps`, `down`, …) just follow the check from scenario 1/2 without retrying. On fallback, `smb.sh` prints `[smb.sh] log bind mount (...) failed, falling back to volume samba_log` to stderr — not an error, the container runs normally.

The default `SMB_LOG_HOST_PATH=/Volumes/RAMDisk/SMB/log` is a RAM disk and is wiped on reboot or unmount — not suitable for logs you need to keep. For durable logs, point `SMB_LOG_HOST_PATH` at a directory on a normal disk.

Note that the current value is a **subdirectory of `SHARE_HOST_PATH_1st`** (`/Volumes/RAMDisk/SMB`), so the `smbd` logs are exposed inside the `onpremise` share, and under the "every subdirectory is a sharepoint" model `log` looks like one. This is a deliberate user choice; to separate them, move `SMB_LOG_HOST_PATH` outside the share root and `--force-recreate`.

Reading logs in the bind-mount scenario:

```bash
ls -l /Volumes/RAMDisk/SMB/log
tail -f /Volumes/RAMDisk/SMB/log/log.<machine>
```

Reading logs in the volume scenario:

```bash
docker run --rm -v samba_log:/l alpine ls -l /l
```

`CONTAINER_LOG_*` is an entirely different mount (`/var/log/samba` → `/Volumes/RAMDisk/log/docker/samba`), always a bind mount, holding three things: `container.log` (stdout/stderr of the entrypoint and `smbd`), Samba's `log.smbd`/`log.rpcd_*`, and the Admin API's [audit log](admin-api.md#audit-log).
