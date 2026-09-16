# common role

Baseline for every Blueforce host: base packages, timezone, and the docs/10
requirement that `unattended-upgrades` stays OFF with `apt-daily*.timer` masked.

## Variables

| Name | Default | Purpose |
|---|---|---|
| `common_timezone` | `Europe/Istanbul` | System timezone |
| `common_admin_user` | `blueforce` | Admin login (SSH key managed per docs/06) |

## Usage

```yaml
- hosts: blueforce
  become: true
  roles:
    - common
```
