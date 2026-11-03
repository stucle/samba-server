# Notes for macOS on Apple Silicon (M2)

**Verdict: it works**, with three caveats: port 445 (see [clients.md](clients.md)), OneDrive, and performance.

## What has been tested

This compose setup has been run for real on Linux (Docker 29, Compose v5). The following behaved correctly:

- Container reaches `healthy`, port mapping `445->445`.
- Reading, writing and creating directories over port 445 on both shares.
- A wrong password and a guest login are both refused.
- Logs land in `SMB_LOG_HOST_PATH` through the bind mount; `smb.sh` falls back to the `samba_log` volume when that path is unusable — see [the three scenarios](configuration.md#log).
- CPU, memory and pids limits are applied.
- `max connections=1` blocks a second client.
- `SMB_CONCURRENT_CONNECTIONS=3` allows exactly three clients.

The most recent test used the `dockurr/samba:4.23` image itself (Samba 4.23.10), amd64 build. **It has not been run on a real Mac**, so the macOS-specific notes below come from documentation rather than measurement.

## Multi-arch image

`dockurr/samba:4.23` publishes both `linux/amd64` and `linux/arm64`. Compose does not set `platform`, so Docker picks the build matching the host CPU: arm64 on an M2, amd64 on Lightsail or an Intel machine. Both run natively, without emulation. If the `DOCKER_DEFAULT_PLATFORM` environment variable is set, Docker uses that instead — so do not set it. The 4.23 branch only receives security patches until 2027-03-31, so move to a newer branch's tag before then, once such an image is published. If the image is missing a VFS module, the entrypoint drops that module and logs a warning.

## CPU / memory

`deploy.resources.limits` takes effect under plain `docker compose up`; Swarm is not needed. The container runs inside the Docker Desktop VM, so the effective limit is the lower of `config.env` and Docker Desktop's Settings → Resources. While idle, Samba uses roughly 6 MiB of memory.

## OneDrive

- Recent OneDrive versions store files under `~/Library/CloudStorage/OneDrive-<name>`. `~/OneDrive` is usually just a symlink, so point `SHARE_HOST_PATH_2nd` at the real path.
- Cloud-only files (Files On-Demand) are downloaded when read. That can be slow, time out, or produce I/O errors such as "Resource deadlock avoided". Enable "Always Keep on This Device" for the folders you share.
- If the container sees an empty directory or reports "Operation not permitted", grant Docker **Full Disk Access** in System Settings → Privacy & Security and restart Docker Desktop.
- Files written over SMB are still synced by OneDrive as usual. Editing the same file over SMB and through the OneDrive web UI can produce a conflict copy.
- Docker Desktop must share `/Users`. It does by default, under Settings → Resources → File sharing.

## Performance (VirtioFS)

Docker Desktop on Apple Silicon uses VirtioFS by default. Large sequential reads and writes are fine. With many small files or large directories it is noticeably slower than macOS's built-in File Sharing. Every request travels: client → Docker Desktop port forward → VM → Samba → VirtioFS → APFS.

If Finder fails to copy because the host directory does not support xattrs, see "macOS metadata" in [configuration.md](configuration.md).

## UID/GID

Set `SMB_UID` and `SMB_GID` in `config.env` to the macOS user running Docker Desktop:

```bash
id -u   # SMB_UID, usually 501
id -g   # SMB_GID, usually 20 (staff)
```

Inside the container Samba touches files as `groot` (`SMB_WRITE_USER`) with that UID/GID. The `readonly` account never writes, so its UID does not matter. On the Mac, files created over SMB still belong to your macOS user.

At startup the entrypoint probes each share for writability. If a probe fails, `./smb.sh logs` shows a warning — check UID/GID, or set `SHARE_FORCE_USER_1st=root` / `SHARE_FORCE_USER_2nd=root` for the affected share.

## Security

- Passwords are stored in plain text in `secrets.env` (`chmod 600`) and are also visible via `docker inspect`.
- The server listens on every interface, so any machine on the LAN can reach it. Do not expose port 445 to the internet.
- SMB1 and guest access are both disabled. Encryption is set to `if_required`.

Sources: [dockurr/samba on Docker Hub](https://hub.docker.com/r/dockurr/samba), [Docker for Mac file sharing](https://github.com/docker/for-mac/issues/6243)
