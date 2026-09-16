# Central monitoring stack (Prometheus + Grafana OSS + Uptime Kuma)

## Start

Create a root-owned password file whose contents are the Grafana first-admin password (no newline is preferred), then start with its absolute path:

```bash
install -m 600 -o root -g root /dev/null /etc/blueforce/grafana-admin-password
# Write the generated password directly to /etc/blueforce/grafana-admin-password.
cd monitoring
GRAFANA_ADMIN_PASSWORD_FILE=/etc/blueforce/grafana-admin-password docker compose up -d
```

`GRAFANA_ADMIN_PASSWORD_FILE` is mandatory. Compose mounts that host file as a Docker secret; it is not stored in the repository or printed in the compose environment. The process owner must keep the file root-owned and mode `0600`. Grafana is available at `http://127.0.0.1:3001`; Prometheus at `:9090`; Uptime Kuma at `:3002`.

## Fleet targets

Field devices are scraped via file-based service discovery in `prometheus/targets/*.json` (see `prometheus/targets/README.md`).

## Alerts

Validate changes with `promtool check rules prometheus/alerts.yml` and `promtool check config prometheus/prometheus.yml`.