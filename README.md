# Samba SMB server (docker compose)

An SMB file server on `dockurr/samba:4.23.8` (pinned by digest in `SMB_BASE_IMAGE`), serving port `445` with two accounts — `readonly` (read) and `groot` (read-write) — and two shares: `onpremise` → `SHARE_HOST_PATH_1st`, `cloud` → `SHARE_HOST_PATH_2nd`. Static settings live in `config.env`, passwords in `secrets.env` (`chmod 600`).

`entrypoint.sh` replaces the image's own entrypoint: it renders `smb.conf` from `config.env` and keeps `log file` working. It is baked into the image rather than bind-mounted, so starting the container never depends on a host file.

**Runtime administration needs no restart.** Every subdirectory of the `onpremise` share is a *sharepoint*; users, sharepoints and access rights are managed live with `smbctl` or the Admin API on `127.0.0.1:444`. See [runtime operations](docs/runtime-operations.md) and [admin API](docs/admin-api.md).

## Configure

Edit `config.env` — and `secrets.env` for credentials — before the first start.

| Group | Variables | File | Notes |
|---|---|---|---|
| Port | `SMB_HOST_PORT`, `SMB_BIND_IP` | `config.env` | `445` on all interfaces (`0.0.0.0`) by default |
| Accounts | `SMB_READ_USER`, `SMB_WRITE_USER`, `SMB_UID`, `SMB_GID` | `config.env` | Match `SMB_UID`/`SMB_GID` to the host user running Docker |
| Passwords | `SMB_READ_PASSWORD`, `SMB_WRITE_PASSWORD` | `secrets.env` | Never enters the build context |
| Admin API | `ADMIN_API_PORT` / `ADMIN_API_USER`, `ADMIN_API_PASSWORD` | `config.env` / `secrets.env` | Bound to `127.0.0.1` only |
| Runtime state | `SMB_STATE_DIR` | `config.env` | Volume `samba_core`: sharepoints and users created at runtime |
| Logging | `SMB_LOG_HOST_PATH`, `SMB_LOG_VOLUME`, `SMB_LOG_LEVEL`, `SMB_MAX_LOG_SIZE` | `config.env` | `smb.sh` picks a bind mount or a volume — see [logging](docs/configuration.md#log) |
| Connections | `SMB_CONCURRENT_CONNECTIONS`, `SMB_MAX_CONNECTIONS` | `config.env` | Server-wide clients / per-share limit |
| Resources | `SMB_CPU_LIMIT`, `SMB_MEM_LIMIT` | `config.env` | |
| Share `onpremise` | `SHARE_NAME_1st`, `SHARE_HOST_PATH_1st`, `SHARE_*_1st` | `config.env` | Root for every runtime sharepoint |
| Share `cloud` | `SHARE_NAME_2nd`, `SHARE_HOST_PATH_2nd`, `SHARE_*_2nd` | `config.env` | Point it at the real OneDrive folder |

Before starting:

- Both `SHARE_HOST_PATH_*` directories must already exist — compose will not create them.
- If `~/OneDrive` is a symlink, point `SHARE_HOST_PATH_2nd` at the real folder under `~/Library/CloudStorage/`.
- Raise `SMB_CONCURRENT_CONNECTIONS` as you add users or sharepoints (`max smbd processes` is that value plus 2). Changing it requires `--force-recreate`.

## Run

```bash
cd <directory holding compose.yaml>
chmod 600 config.env secrets.env
chmod +x entrypoint.sh smb.sh smbctl

./smb.sh up -d                # build and start
./smb.sh ps                   # both smb-pod and smb-admin must be (healthy)
./smb.sh logs -f              # startup output and warnings
./smb.sh state show           # sharepoints and users created at runtime
./smb.sh state export <dir>   # back the state volume up before `down -v`
./smb.sh down                 # stop
```

Always go through `./smb.sh`, never `docker compose` directly: it supplies `--env-file config.env` and selects the log mount overlay. After editing `config.env` or `entrypoint.sh`, run `./smb.sh up -d --force-recreate` — the image is rebuilt automatically. The line `[smb.sh] log bind mount (...) failed, falling back to volume samba_log` is a notice, not an error: the container is healthy and logs are in a Docker volume instead of `SMB_LOG_HOST_PATH`.

Connect from Finder with `Cmd+K` → `smb://groot@<mac-ip>:445/onpremise`, or `readonly@` for read-only access. The server never shows up in network browsing (Docker NAT blocks NetBIOS/mDNS) — always connect by IP.

## Documentation

- [Client setup](docs/clients.md) — macOS, Windows, Linux, iOS, and port caveats
- [macOS Apple Silicon notes](docs/macos-notes.md) — OneDrive, performance, UID/GID, security
- [Configuration reference](docs/configuration.md) — image, every variable, volumes, adding a share
- [Runtime operations](docs/runtime-operations.md) — `smbctl`, the sharepoint model, state and backups
- [Admin API](docs/admin-api.md) — five endpoints, basic auth, audit log
