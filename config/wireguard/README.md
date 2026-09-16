<!-- Purpose: Explain how to turn wg0.conf.example into a live spoke config. -->
<!-- Scope: Hub-spoke layout, peer naming, keepalive, PostUp/PostDown, bring-up. -->
<!-- Safety: No secrets here; every key and address marked <REPLACE> stays out of git. -->
# WireGuard spoke reference

Ref: `docs/08-WIREGUARD-AND-NETWORK.md` (K-05), naming `K-12`.

## Layout

- Hub-spoke: the central server is the hub (`10.8.0.1`), each field device is a spoke.
- Peer name equals the device identity: `bf-<8digits>` (hostname, inventory, monitoring label).
- Each spoke gets one fixed tunnel IP (`10.8.0.x/32`) from inventory.

## Filling the example

1. Copy `wg0.conf.example` to `/etc/wireguard/wg0.conf` (mode `600`).
2. Replace `Address` with the device tunnel IP from inventory.
3. Replace `<REPLACE_DEVICE_PRIVATE_KEY>` with the device private key.
4. Replace `<REPLACE_HUB_PUBLIC_KEY>` and `<REPLACE_HUB_HOST>` with hub values.
5. Keep `PersistentKeepalive = 25` (official reasonable default for NAT peers).
6. Keep `PostUp`/`PostDown`: they scope SSH (22) and RDP (3389) rules to `wg0`.

## Bring-up

```bash
sudo install -m 600 wg0.conf /etc/wireguard/wg0.conf
sudo systemctl enable --now wg-quick@wg0
sudo wg show wg0 latest-handshakes
```

## Notes

- Spokes behind CGNAT must always initiate outward; the hub only listens on `51820/udp`.
- Placeholders marked `<REPLACE>` must never hold real keys in this repo.
