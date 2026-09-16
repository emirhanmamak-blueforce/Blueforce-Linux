# RustDesk Self-Hosted Server (hbbs + hbbr)

OSS rendezvous + relay server for the Blueforce fleet. Field clients reach
the VDS public address directly over the internet, independent of WireGuard:
if the tunnel drops, this channel stays up (requires field internet + VDS up).

## Prerequisites

- A central VDS with a public DNS name (example: `rustdesk.example.com`).
  Use your real DNS name; the value below is a placeholder.
- TCP/UDP ports 21115-21117 reachable from the internet (see port table in
  `docker-compose.yml`). Keep 21118/21119 closed unless the web client is used.
- Docker Engine + Docker Compose plugin on the VDS.

## Setup

```bash
cd rustdesk
docker compose up -d
# First start generates the keypair in ./data (id_ed25519 + id_ed25519.pub).
cat data/id_ed25519.pub   # <-- public key; embed in field clients
docker logs bf-hbbs       # verify hbbs listening
docker logs bf-hbbr       # verify hbbr listening
```

## Key distribution (field clients)

1. Read the public key: `cat data/id_ed25519.pub` (single line, no newline issues).
2. Bake into the golden image / deployment script together with the server address:
   `rustdesk.example.com` (replace with the real VDS DNS name).
3. Client config keys: `host = rustdesk.example.com`, `key = <id_ed25519.pub content>`.
4. Tag each client with its device identity `BF-<no>` so the RustDesk address
   book matches the Ansible inventory and MeshCentral names.
5. Key rotation: deploy the new key alongside the old one, confirm clients
   connect, then retire the old key.

## Health monitoring

Point Uptime Kuma (see `../monitoring`) at:

- TCP 21116 (hbbs heartbeat)
- TCP 21117 (hbbr relay)

## Notes

- `network_mode: host` is intentional; do not add port mappings.
- Data directory `./data` holds the keypair; back it up (see 17-BACKUP-RECOVERY).
- Never commit the private key (`data/id_ed25519`) to Git.
