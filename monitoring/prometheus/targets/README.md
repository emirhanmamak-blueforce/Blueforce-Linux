# File-based service discovery for the 700-device fleet.
#
# Prometheus watches this directory (refresh 30s); adding or removing a
# `*.json` file takes effect without a reload or restart.
#
# Per-device entry template (WireGuard address as target, identity label
# contract `device_id="BF-<no>"` on every target):
#
#   [
#     {
#       "targets": ["10.7.0.11"],
#       "labels": {"device_id": "BF-12010193", "site": "pilot", "job": "node"}
#     }
#   ]
#
# Scale-out: generate one file per site/region (e.g. `site-ankara.json`)
# from the Ansible inventory; keep each file under a few thousand targets.
