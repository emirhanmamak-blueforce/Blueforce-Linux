# monitoring role

Installs and starts the node exporter and verifies the docs/10 requirement
that automatic upgrades stay disabled.

## Variables

| Name | Default | Purpose |
|---|---|---|
| `monitoring_packages` | `prometheus-node-exporter` | Packages to install |
| `monitoring_service` | `prometheus-node-exporter` | Service to enable |
| `monitoring_endpoint` | `http://monitoring.example.com:8428` | Metrics endpoint (placeholder) |
| `monitoring_job` | `blueforce` | Job label |

## Usage

```yaml
- hosts: blueforce
  become: true
  roles:
    - monitoring
```
