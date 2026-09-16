# Blueforce installer (`scripts/install/`)

Single entry point: `sudo ./blueforce-install.sh --dealer-id <8 digits>`.

- Orchestrator: `blueforce-install.sh` (dealer-id gate `^[0-9]{8}$`,
  hostname `bf-<no>` + device `BF-<no>`, ordered module runs, `--resume`,
  results to `/var/log/blueforce-install.log` + `/var/lib/blueforce/install-state`).
- Modules: `installer/modules/01-*.sh` … `18-*.sh`. Every module is idempotent
  and supports `--check` (read-only audit). Exit `0` = OK, `3` = SKIP.
- Required remote-channel preconditions: set per-device `WG_ADDRESS`, `WG_ENDPOINT`,
  and `WG_PEER_PUBKEY`; WireGuard readiness requires a peer handshake no older than
  `BF_WG_HANDSHAKE_MAX_AGE` seconds (default `180`) unless `REQUIRE_WIREGUARD=false`.
  Set `RUSTDESK_SERVER` to a real self-hosted endpoint and provide the pinned local
  `RUSTDESK_DEB`; placeholders are rejected.
- Docker published ports default to deny. Add only reviewed `tcp PORT` or `udp PORT`
  entries to `/etc/blueforce/docker-published-port-allowlist.conf`; the enabled
  `blueforce-docker-firewall.service` reapplies that policy after Docker starts.
- Exit codes: `0` READY · `1` module failure · `2` argument/format error.

Module map: 01-precheck · 02-system · 03-user · 04-hostname · 05-network ·
06-wireguard · 07-ssh · 08-rdp · 09-rustdesk · 10-docker · 11-meg ·
12-monitoring · 13-firewall · 14-update-policy · 15-logrotate · 16-gui ·
17-healthcheck · 18-final-check.

NOTE on AnyDesk: there is deliberately no AnyDesk module. Remote access is
covered by SSH-over-WireGuard, xRDP and RustDesk. AnyDesk stays a manual,
per-device exception outside this installer.
