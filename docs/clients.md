# Connecting from a client

`onpremise` and `cloud` are **share names**, not paths.

| Client | Command |
|---|---|
| macOS Finder | `Cmd+K` → `smb://groot@<mac-ip>:445/onpremise`. On the machine running the server: `smb://groot@127.0.0.1:445/onpremise` |
| macOS Terminal | `mount_smbfs //groot@<ip>:445/onpremise ~/mnt/onpremise` |
| Windows 11 24H2+ / Server 2025 | `net use Z: \\<ip>\onpremise /TCPPORT:445 /user:groot`, or `New-SmbMapping -TcpPort 445` |
| Windows 10 / Windows 11 before 24H2 | Cannot connect directly (see below) |
| Linux | `mount -t cifs //<ip>/onpremise /mnt/onpremise -o port=445,username=groot,vers=3.0`, or `smbclient //<ip>/onpremise -p 445 -U groot` |
| iOS Files | `smb://<ip>:445` |

## About port 445

The server uses the default SMB port (445), so clients need not specify one — every command above works without `:445` / `-p 445` / `/TCPPORT:445`.

- macOS: **turn File Sharing off** (System Settings → General → Sharing) before starting, otherwise port 445 on the host is already taken and the container cannot bind it.
- The server does not appear under Network in Finder or Explorer, because Docker's NAT blocks NetBIOS and mDNS. Always connect by IP address.
- On the first run, the macOS firewall may ask whether to let Docker accept incoming connections.
- To move off port 445 (for example `SMB_HOST_PORT=444`): Windows supports a non-445 port only from Windows 11 24H2 / Server 2025 onwards. On older Windows you need `netsh interface portproxy` to forward port 445 on a secondary loopback address to `<mac-ip>:<port>`.

Source: [SMB alternative ports](https://thewindowsupdate.com/2023/11/08/smb-alternative-ports-now-supported-in-windows-insiders/)
