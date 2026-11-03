# Admin API (`smb-admin`)

An HTTP wrapper around [`smbctl`](runtime-operations.md): five endpoints, basic auth, one JSON audit line per request. A Go service with no dependencies beyond the standard library, running in its own container (`smb-admin`), so a crash there cannot take `smbd` down.

```
POST   /account                              {"user":"alice","password":"...","group":"sp_alpha_r"}
DELETE /account/{user}
POST   /sharepoint                           {"name":"alpha"}
POST   /sharepoint/{name}/grants             {"user":"alice","mode":"r"}   # or "rw"
DELETE /sharepoint/{name}/grants/{user}      ?mode=w (default) | all
```

| Code | When |
|---|---|
| `200` / `201` | Success (`201` for the two creating endpoints, `/account` and `/sharepoint`) |
| `400` | Validation failed (name off the regex, bad mode, malformed JSON, empty password) |
| `401` | Basic auth failed |
| `500` | `smbctl` exited non-zero; its output is included, sanitized to a single line with no control characters |

Beyond those five there is one more route: `GET /healthz` (no auth, returns `ok`) so the Compose healthcheck has something to call. There is no archive-log endpoint — log rotation runs on a schedule, not through the API.

`group` in `POST /account` is **optional**: when present, the user is added to that Unix group at creation time (the group is created if missing) and it is recorded in `accounts.tsv`.

The `mode` of `DELETE .../grants/{user}` matches `smbctl revoke` exactly: `w` (the default) drops write access and **keeps read**, `all` drops both. The default is `w` so the CLI and the API cannot drift apart — a full revocation must pass `?mode=all`.

## Examples

```bash
curl -su groot:IamGroot -X POST localhost:444/sharepoint -d '{"name":"beta"}'
curl -su groot:IamGroot -X POST localhost:444/account    -d '{"user":"alice","password":"..."}'
curl -su groot:IamGroot -X POST localhost:444/sharepoint/beta/grants -d '{"user":"alice","mode":"rw"}'
curl -su groot:IamGroot -X DELETE 'localhost:444/sharepoint/beta/grants/alice?mode=all'
curl -su groot:IamGroot -X DELETE localhost:444/account/alice
```

## Network and port

`ports: ["127.0.0.1:${ADMIN_API_PORT}:8333"]` — the process listens on **8333 inside the container**, and Docker binds `127.0.0.1:444` on the host.

Why not listen on 444 directly inside the container: 444 is a privileged port. On Docker Desktop it would bind anyway, because the LinuxKit VM sets `net.ipv4.ip_unprivileged_port_start = 0` (i.e. there are no privileged ports at all), but on a real Linux Docker host (`ip_unprivileged_port_start = 1024`) a non-root process would fail with `bind: permission denied`. Mapping 444→8333 is correct on every host.

And **no** `cap_add: [NET_BIND_SERVICE]`: measured directly — that bit is already in Docker's default bounding set (`CapBnd` is identical with and without `cap_add`), and for a non-root process `CapPrm = CapEff = 0` regardless of `cap_add`, because `CapBnd` is only a **ceiling**, not a grant. The line is a no-op.

The bind address `127.0.0.1` is hardcoded in `compose.yaml`, with no variable, so it cannot be misconfigured onto the LAN. To check: from another machine on the LAN, `curl http://<mac-ip>:444/` must **not** connect.

## Auth

`ADMIN_API_USER` / `ADMIN_API_PASSWORD` live in `secrets.env` (never interpolated into `compose.yaml`, only passed through `env_file:`). They are compared with `crypto/subtle.ConstantTimeCompare`, and both username and password are always compared — no early return.

This is the **only** protection: any process on the machine can reach `127.0.0.1:444`. Acceptable at the scale of one user on one machine.

The credentials are a **separate pair of variables** from `SMB_WRITE_USER`/`SMB_WRITE_PASSWORD`, even though the values currently coincide with `groot`: changing the SMB password must not lock the Admin API out, and changing the Admin API identity must not touch the Samba configuration.

## Why `docker.sock` is mounted directly instead of behind `docker-socket-proxy`

`docker.sock` is equivalent to root on the host. `tecnativa/docker-socket-proxy` with `CONTAINERS=1` + `POST=1` filters by *resource type* and *HTTP method*, **not** by container — which is enough to `POST /containers/create` a new container that bind-mounts the host's `/`, or mounts `samba_private` to read `passdb.tdb`, or overwrites this very audit log. See the risk table in `analyze-new-requirement.md` §5.6.

So this Go service **is** the narrow proxy, and the only thing touching the socket:

- The target container name (`smb-pod`) is a **compile-time constant** in the binary, never taken from a request.
- Exactly two Docker API endpoints are called: `POST /v1.43/containers/smb-pod/exec` and `POST /v1.43/exec/{id}/start` (plus `GET /exec/{id}/json` for the exit code, and `GET /_ping` at startup).
- It **never** calls `/containers/create`, `DELETE /containers/{id}`, `/stop`, `/kill` or `/restart`.
- `Cmd` is an **argv array** built from validated input — no shell is involved, so there is nothing for a `;` or a `'` to escape into.
- `:ro` on the socket mount was **dropped**: read-only applies to the socket *file*, while a client can still `connect()` and POST normally. It is not a protection layer, and keeping it would only mislead.

The remaining trade-off: an RCE bug in this service is still equivalent to root on the host. But the surface that could produce such a bug is five endpoints plus the validation logic, rather than the whole Docker Engine API.

The container runs non-root (`uid 10001`, see `admin/Dockerfile`). On Docker Desktop the socket is `root:root` mode `0660`, so `compose.yaml` grants the supplementary group `0` (`group_add: ["0"]`) — that, not running as root, is what allows opening the socket. The service pings the Docker API at startup and **fails immediately** with a specific hint if it cannot, instead of failing on the first request.

## Audit log

`$CONTAINER_LOG_DIR/audit-YYYYMMDD.log` (by default `/var/log/samba`, mapped to `CONTAINER_LOG_HOST_PATH` = `/Volumes/RAMDisk/log/docker/samba`), one file per day in host time (`TZ=Asia/Ho_Chi_Minh`), append-only, JSON lines:

```json
{"ts":"2026-11-03T15:20:01+07:00","actor":"groot","method":"POST","path":"/sharepoint","input":{"name":"alpha"},"result":"ok","detail":"[smbctl] sharepoint 'alpha' ready at /shares/onpremise/alpha"}
```

- It sits next to Samba's own logs (`log.%m`, `log.smbd`, `container.log`) — reusing an existing mount, creating no new directory.
- `401` and `400` requests are logged too (`actor` = the attempted user), but **never a password**: the `password` field is excluded from `input` in the handler itself, not filtered at write time.
- Every line also goes to `docker logs smb-admin`, so a trace survives even if the file cannot be written.
- **No rotation or retention of its own** — the same philosophy as the existing `smbd` logs. Pruning is manual.
- The audit log is not the only source for an investigation: cross-check it against the `smbd` logs when it matters.
