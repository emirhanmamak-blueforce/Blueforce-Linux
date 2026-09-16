# docker role

Installs the pinned Docker engine, enables the daemon, and reports the MEG
container state. Image and package tags are always pinned; `latest` and
Watchtower-style auto-updaters are forbidden (docs/10, docs/12).

## Variables

| Name | Default | Purpose |
|---|---|---|
| `docker_packages` | pinned `docker-ce=...` | Exact engine packages to install |
| `meg_container_name` | `meg` | Container name to report on |
| `meg_image_tag` | `1.0.0` | Pinned MEG image tag |

## Usage

```yaml
- hosts: blueforce
  become: true
  roles:
    - docker
```
