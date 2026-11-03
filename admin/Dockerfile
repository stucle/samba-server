# Multi-stage: the Go toolchain never ships in the runtime image,
# which ends up  holding a single static binary plus tzdata (the audit log file name follows the  host's TZ, Asia/Ho_Chi_Minh).
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
# No external dependencies on purpose: net/http (method+path patterns), crypto/subtle
# and net are enough, so there is no module download and nothing to audit.
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/smb-admin .

FROM alpine:3.21
RUN apk add --no-cache tzdata \
 && adduser -D -H -s /sbin/nologin -u 10001 smbadmin
COPY --from=build /out/smb-admin /usr/local/bin/smb-admin
# Non-root: the process binds 8333 (never a privileged port) and holds no user
# data. docker.sock access comes from the supplementary group granted in
# compose.yaml (group_add: ["0"]), not from running as root.
USER 10001:10001
EXPOSE 8333
ENTRYPOINT ["/usr/local/bin/smb-admin"]
