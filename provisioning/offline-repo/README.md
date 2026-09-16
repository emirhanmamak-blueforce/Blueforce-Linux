# Offline APT repository

Reviewed `.deb` files are not stored in this repository. Supply them locally on the LAB build machine; the tooling never fetches a package, never resolves a dependency from a remote source, and never signs anything.

## Current state (read this first)

- **This repository contains no packages and no built repository.** `packages/` holds only `.gitkeep`, and there is no `pool/`, `Packages`, `Packages.gz`, `packages.lock.tsv` or `SHA256SUMS` anywhere in the tree.
- `manifests/*.txt` is the **package contract**. Every line is `package=version`. The package names are final and complete; the version field still reads the sentinel `UNPINNED` because no package has been acquired or reviewed yet.
- The versions must be filled on the LAB build machine from the reviewed `.deb` files. Until then everything fails closed: `--check` and a real build refuse a pin whose version is still `UNPINNED`, and the offline installer refuses a bundle whose lock does not satisfy the manifests.
- Nothing here was built on a workstation: `apt-ftparchive` and `dpkg-deb` exist only on the Ubuntu 26.04 build host, so no bundle was produced and no `.deb` was downloaded. `--dry-run-plan` is the only mode that runs anywhere.

## Contract files

| File | Role |
|---|---|
| `manifests/base-packages.txt` | Base system pins: tooling, SSH, WireGuard, SMART, firewall, node exporter (installer modules 02, 06, 07, 12, 13) |
| `manifests/remote-access.txt` | Remote access and desktop pins: xRDP, GNOME session, minimal desktop, RustDesk (modules 08, 09, 16) |
| `manifests/docker.txt` | Docker CE pins (module 10) |
| `manifests/requirements.tsv` | Audit table: which manifest must pin which package, and which installer module or diagnostic needs it |
| `manifests/packages.lock.schema.tsv` | Documented layout of the `packages.lock.tsv` SBOM that a build writes into the bundle |

`scripts/install/blueforce-install.sh --offline` reads **every** `manifests/*.txt` as a pin manifest: an empty or comment-only manifest, an invalid pin, or a pin that is missing from the bundle stops the installer before any package module runs. Adding a `*.txt` file to `manifests/` is therefore a change to that contract, not a local convenience — `manifests/requirements.tsv` must be updated in the same edit.

## Modes

```bash
# Static contract validation: no apt-ftparchive, no dpkg-deb, no pool, no network.
./build-offline-repo.sh --dry-run-plan

# LAB only: verify that the supplied pool satisfies every pin.
./build-offline-repo.sh --packages /secure/reviewed-debs --output /tmp/blueforce-apt --check

# LAB only: build the bundle.
./build-offline-repo.sh --packages /secure/reviewed-debs --output /srv/blueforce-apt
```

`--dry-run-plan` validates the pin format, duplicate and whitespace errors, placeholder leakage, the audit table, the SBOM schema, and the presence of every required package, then prints the missing versions and missing packages as explicit lists. It exits non-zero while anything is unfilled, and it needs no build tooling, so it runs on any machine. It never writes to the manifests.

`--check` and a real build require `apt-ftparchive` and `dpkg-deb`; without them the tooling refuses and names the missing tool. A real build also refuses to overwrite an existing output directory.

## LAB build machine requirements

1. Ubuntu 26.04 LTS build host, the release named in every manifest, `amd64`.
2. `apt-ftparchive` (package `apt-utils`) and `dpkg-deb` (package `dpkg`) installed.
3. A connected acquisition host to obtain and review the `.deb` files for that release, including the packages that are **not** in the Ubuntu archive: `rustdesk` (vendor build) and the Docker CE set (`docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`).
4. A review step that records exactly what was accepted: package, version, architecture, SHA256 and source file name, in the layout of `manifests/packages.lock.schema.tsv`.

### Fill procedure

1. Put the reviewed `.deb` files in one directory, for example `/secure/reviewed-debs`.
2. For each manifest line, read the exact version with `dpkg-deb -f <file>.deb Package Version` and replace `UNPINNED` with it. One pin per package across all manifests.
3. Run `./build-offline-repo.sh --dry-run-plan` until it prints `PLAN READY` (`missing_packages=0` and `errors=0`).
4. Run `--check` against the reviewed pool, then build into a fresh output directory.
5. Archive the bundle, the ISO manifest and the reviewed pool together, since the bundle is the only proof of what a device installed.

## What a build produces

`<output>/pool/*.deb`, `Packages`, `Packages.gz`, `packages.lock.tsv` (package, version, architecture, sha256, source) and `SHA256SUMS` covering the indexes and the lock file.

## Air-gapped target

- The bundle is copied to the target device as `/opt/blueforce/offline-repo`, the default of `BF_OFFLINE_REPO`.
- `scripts/install/blueforce-install.sh --offline` requires that directory to exist with `Packages`, `Packages.gz`, `packages.lock.tsv` and `SHA256SUMS`, runs `sha256sum -c SHA256SUMS`, verifies the lock layout, and checks every manifest pin against a lock row and a pool file.
- Only then does it write `<STATE_DIR>/offline.list` containing exactly `deb [trusted=yes] file:/opt/blueforce/offline-repo ./` and export an isolated APT configuration that points at that file. No remote source, key download, `curl`, `wget` or `apt download` is used.
- An offline installation ends in `PROVISIONED_OFFLINE`. The device is not `READY` until enrollment and central channel verification have succeeded.

## LAB checklist

- [ ] Every `manifests/*.txt` pin carries a real version from a reviewed `.deb`; `--dry-run-plan` prints `PLAN READY`.
- [ ] `manifests/requirements.tsv` still matches the manifests (the plan fails on drift in either direction).
- [ ] `--check` passes against the reviewed pool and the built bundle verifies with `sha256sum -c SHA256SUMS`.
- [ ] The reviewed pool and the bundle are archived together with the ISO release manifest.
- [ ] `tests/check-offline-repo-static.sh` passes in CI.
