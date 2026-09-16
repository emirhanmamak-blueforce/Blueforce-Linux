# wireguard role

Installs WireGuard, writes `/etc/wireguard/<iface>.conf` from variables, and
starts `wg-quick@<iface>`. Private keys are secrets: supply them through the
Semaphore Community encrypted Key Store or another controller-side secret
source; never commit them to Git.

## Variables

| Name | Default | Purpose |
|---|---|---|
| `wg_interface` | `wg0` | Interface name |
| `wg_address` | _(empty)_ | Required client tunnel address, e.g. `10.42.3.11/16` |
| `wg_dns` | _(empty)_ | Optional DNS |
| `wg_private_key` | _(empty)_ | Required client private key (secret) |
| `wg_hub_public_key` | _(empty)_ | Required hub public key |
| `wg_hub_endpoint` | `vpn.example.com:51820` | Required hub endpoint |
| `wg_allowed_ips` | `10.42.0.0/16` | Required allowed IPs |
| `wg_keepalive` | `25` | Persistent keepalive seconds |

The role fails closed when any required tunnel value is empty.

## Usage

```yaml
- hosts: blueforce
  become: true
  roles:
    - role: wireguard
      vars:
        wg_address: 10.42.3.11/16
```
