# ISO builder

`build-blueforce-iso.sh` produces the blueforce field-installation medium from a local,
SHA256-verified Ubuntu ISO. Nothing is downloaded: the base ISO and its checksum record
must already exist on the build host.

```bash
# validate every precondition, write nothing
./build-blueforce-iso.sh \
  --upstream-iso /media/ubuntu.iso \
  --checksum-file ./ubuntu-26.04.1-SHA256SUMS \
  --check

# real build (writes dist/Blueforce-Field-OS-<version>-amd64.iso and its manifest)
./build-blueforce-iso.sh \
  --upstream-iso /media/ubuntu.iso \
  --checksum-file ./ubuntu-26.04.1-SHA256SUMS
```

## Output contract

| Artifact | Path |
|---|---|
| Bootable medium | `dist/Blueforce-Field-OS-<version>-amd64.iso` |
| ISO checksum | `dist/Blueforce-Field-OS-<version>-amd64.iso.sha256` |
| Release manifest | `dist/<version>-manifest.yaml` |

The manifest carries `field_os_version`, `base_os`, `base_flavor`, `base_iso_filename`,
`ubuntu_version`, `ubuntu_iso_sha256`, `git_commit`, `build_date`, `architecture`,
`iso_sha256` and the `packages` block (`rustdesk`, `docker`, `xrdp`, `wireguard`,
`meg_package_version`, `blueforce_installer_version`). `ubuntu_iso_sha256` is always
recomputed from the real base ISO file; no digest is hard-coded anywhere in the tooling.
Package versions are read from the embedded offline APT lock file; when no built
offline repository is embedded they are reported as `unknown` on purpose instead of
being invented.

## Media layout

```text
/autoinstall.yaml                                  assisted autoinstall, read from the medium itself
/boot/grub/grub.cfg                                boot config: every kernel line requests autoinstall
/boot/grub/grub.cfg.blueforce-orig                 pristine copy of the original boot config
/blueforce-provisioning/autoinstall/               same configuration in NoCloud/seed form
/blueforce-provisioning/firstboot/                 bf-firstboot + blueforce-firstboot.service
/blueforce-provisioning/offline-repo/              offline APT tooling, pin manifests, optional built repo
/blueforce-provisioning/release/                   blueforce-release, media-info.yaml, release manifest
```

`interactive-sections: [storage]` is preserved, so the medium installs unattended but the
operator still selects and confirms the target disk on the installer screen. There is no
automatic wipe. Device identity (`BF-<no>`), dealer id, private keys and passwords are
never embedded in the medium; they are collected at firstboot, and the builder refuses to
run when its input scan finds them.

## Boot layout: why the boot structure is rebuilt, not replayed

Ubuntu live ISOs keep part of their boot information outside the ISO 9660 tree, so
`xorriso -boot_image any replay` cannot re-establish it:

1. the **GRUB2 MBR boot code** lives in the first 16 sectors of the source image, and
2. the **EFI system partition is an appended partition**, i.e. a byte range after the ISO
   filesystem rather than a file in it.

Replaying that layout fails with `Cannot enable EL Torito boot image #1 because it is not
a data file in the ISO filesystem` and with the GRUB2 MBR error that it cannot refer to
data outside the ISO 9660 filesystem.

The builder therefore asks the base ISO for its own recipe — `xorriso -indev <base.iso>
-report_el_torito as_mkisofs` — and writes the new medium with `xorriso -as mkisofs` plus
that recipe (`--grub2-mbr`, `-partition_offset`, `-append_partition 2 <guid>`,
`-appended_part_as_gpt`, the BIOS `-b /boot/grub/i386-pc/eltorito.img` entry with
`--grub2-boot-info`, and the alternate UEFI entry). Interval references in the recipe are
rewritten to point at the base ISO, never at the output, and the builder fails closed when
the recipe has no `-append_partition` line. Nothing about the layout is hard-coded, so a
Server ISO or a later Ubuntu revision works without editing the script.

The extracted tree is only ever *added to*: `autoinstall.yaml`, `/blueforce-provisioning/`
and the patched boot configuration (with its `.blueforce-orig` backup). Existing boot
files (`boot.catalog`, `eltorito.img`, `casper/*`) are left byte-identical.

## Flavour-agnostic base ISO (and the recorded baseline deviation)

`--upstream-iso` accepts an Ubuntu Server **or** Ubuntu Desktop ISO. The flavour is read
from the ISO volume label (`Ubuntu-Server 26.04.1 LTS amd64` → `server`,
`Ubuntu 26.04.1 LTS amd64` → `desktop`), recorded as `base_flavor`, and never guessed
from the file name.

The architecture documents fix the baseline as *Ubuntu Server 26.04.1+ LTS*
(`docs/24` K-01, `docs/26`). The verified installation medium available on this build
host is the **Desktop** flavour ISO, so builds made from it deviate from that baseline.
The deviation is not hidden: it is written into `manifest.yaml` as `base_flavor: desktop`
plus a `baseline_deviation` block (reason, impact, decision needed, `lab_required: true`),
and mirrored into `media-info.yaml` and `/etc/blueforce-release` on the medium.

* The Desktop medium already ships GNOME, so the desktop/GNOME layer needs no extra
  installation step on the target (`docs/24` K-02, `docs/07` xrdp + GNOME).
* A Server-based build remains a single flag away:
  `--upstream-iso /path/ubuntu-26.04.1-live-server-amd64.iso` produces a medium whose
  manifest reports `base_flavor: server` and `baseline_deviation: none`.
* The autoinstall path on the Desktop flavour still requires LAB acceptance before any
  production use; see `tests/qemu-field-os-test-plan.md`.

## Offline APT repository

* `--offline-repo DIR` embeds a built repository (`Packages`, `Packages.gz`, `SHA256SUMS`,
  `packages.lock.tsv` are mandatory; an incomplete directory is rejected with a clear
  error). Without the flag, `provisioning/offline-repo/build` is auto-detected.
* The repository is placed at `/blueforce-provisioning/offline-repo/built/` on the medium
  and late-commands merge it into `/opt/blueforce/offline-repo` on the installed system,
  which is where `blueforce-install.sh --offline` expects it.
* When no built repository is available the medium still ships the pin manifests and
  tooling, `media-info.yaml` records `offline_repo_status: not-included`, and the target
  keeps failing closed with `OFFLINE BLOCKED` until a repository is built and re-embedded.
  `--require-offline-repo` turns that condition into a build failure for release builds.

## Scratch space and determinism

* The build extracts the base ISO and writes a new one, so it needs about **2x the base
  ISO size** free. `--work-dir` overrides the scratch location; otherwise the output
  filesystem, `$TMPDIR` and `/var/tmp` are tried in order and the build stops with an
  explicit error when none has room. It never downloads anything to work around space.
* No build timestamp is written into the medium (the date lives in the dist manifest
  only) and generated files get a fixed modification time. `--reproducible` pins the
  volume-level date through the mkisofs-compatible `--modification-date=<stamp>` option;
  the base ISO's own `--modification-date` recipe line is deliberately dropped so the
  stamp stays under this script's control.
* The ISO volume label defaults to the base ISO's label, which keeps live-media discovery
  untouched; `--volid` overrides it (xorriso warns when a label does not follow ISO 9660
  rules, for example spaces) and the value is recorded in the manifest.

## Verification steps performed by the builder

1. xorriso is present and can read the base ISO's El Torito boot metadata.
2. Base ISO SHA256 is recomputed and matched against `--checksum-file`.
3. Media inputs are scanned for device identity, private keys and credentials.
4. The pristine GRUB configuration is kept as `grub.cfg.blueforce-orig` before injection;
   injection is idempotent and `autoinstall` is placed ahead of the `---` separator.
5. After writing, the produced ISO is re-opened with xorriso: BIOS **and** UEFI El Torito
   entries must still exist, `/autoinstall.yaml` must contain the interactive-storage and
   `offline-install` markers, the GRUB configuration must request autoinstall, and the
   firstboot/release/offline-repo payloads must be present. Any failure removes the broken
   output instead of leaving a half-good artifact behind.

## Still LAB work

Booting the medium with UEFI, Legacy BIOS and Secure Boot, verifying that the autoinstall
configuration is picked up on the chosen flavour, and a full air-gapped install are LAB
tasks; no VM is started by the tooling or by this repository's tests. Use
`tests/qemu-field-os-test-plan.md`.

## Files

| File | Role |
|---|---|
| `build-blueforce-iso.sh` | the builder (real build, `--check` for dry runs) |
| `verify-upstream-iso.sh` | SHA256 verification of a local ISO against a checksum record |
| `test-iso.sh` | non-destructive checks of an existing ISO artifact |
| `field-os-version` | Field OS version used in artifact names (`--version` overrides) |
| `ubuntu-26.04.1-SHA256SUMS` | checksum record fetched verbatim from `https://releases.ubuntu.com/26.04.1/SHA256SUMS`; the Desktop ISO used for LAB builds matches its `ubuntu-26.04.1-desktop-amd64.iso` line |
