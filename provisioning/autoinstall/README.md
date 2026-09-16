# Autoinstall

Ubuntu Subiquity autoinstall v1 baseline for the Blueforce Field OS medium. It is
identity-free and stays operator-assisted.

- `autoinstall.yaml` is copied to the root of the installation medium as
  `/autoinstall.yaml`, which is where Subiquity reads configuration from the medium
  itself; `build-blueforce-iso.sh` also ships a copy under
  `/blueforce-provisioning/autoinstall/`.
- `user-data` is the NoCloud transport for the V1 "official ISO + seed USB" flow. Its
  autoinstall block is kept identical to `autoinstall.yaml` so both flows behave the same.
- `interactive-sections: [storage]` is mandatory. The technician selects and confirms the
  target disk on the installer screen; V1 never wipes a disk automatically.
- `apt.fallback: offline-install` is explicit: when no primary mirror is reachable,
  Subiquity reverts to an offline installation from the medium instead of aborting.
- `late-commands` only copy reviewed medium content into the target: the offline APT
  repository to `/opt/blueforce/offline-repo`, the firstboot payload to
  `/usr/local/sbin/bf-firstboot`, its service unit to `/etc/systemd/system/`, the release
  identity to `/etc/blueforce-release`, and the service is enabled. It stays inert until
  an operator supplies the dealer ID and the authorised public key on the installed
  system (`ConditionPathExists=` guards in the unit).
- No `identity` block, user, password, SSH key, dealer id or disk directive belongs here;
  device identity is collected at firstboot (K-09/K-12). The static test suite enforces
  this, and `build-blueforce-iso.sh` re-scans its inputs before it writes a medium.

Flavour note: this configuration is written for the Ubuntu installer's autoinstall
contract. The LAB build base is currently the Desktop flavour ISO (see `../iso/README.md`);
the autoinstall path on that flavour must be accepted in the LAB matrix before production
use.
