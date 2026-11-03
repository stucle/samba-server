# Bakes entrypoint.sh into the image so starting the container never depends on a host file being present. See docs/configuration.md#image-and-entrypoint. 
# The stock entrypoint is replaced because it runs smbd with --debug-stdout (which makes Samba ignore "log file") and only supports one share via env vars.
#
# BASE_IMAGE comes from SMB_BASE_IMAGE in config.env, pinned by digest.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# smbctl is baked in for the same reason: `docker exec smb-pod smbctl ...`
# (and the Admin API, which execs it) must not depend on a host file being present.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY smbctl /usr/local/bin/smbctl
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/smbctl
