# Windows → Field OS migration tooling (`scripts/migration/windows/`)

Read-only inventory and export-manifest tooling that runs **on the Windows
terminal before it is migrated** to Blueforce Field OS (docs/28). It never
installs, never writes to the machine, never touches a service, the registry or
the network configuration, and never collects credentials or secrets.

## Files

| File | Report type | Purpose |
|---|---|---|
| `BF-WindowsPreMigrationInventory.ps1` | `windows-pre-migration-inventory` | Hardware, Windows version, disks/volumes, network (IP/DNS/gateway/routes/profiles/proxy), serial-COM ports, USB devices + hardware IDs, drivers, installed software, services, scheduled tasks, Docker presence, VPN clients, RustDesk/AnyDesk IDs, MEG paths, current hostname. |
| `BF-WindowsDataExport.ps1` | `windows-pre-migration-data-export-manifest` | Metadata-only review manifest for the manual data transfer: candidate user folders, removable media, mapped network drives, printers, MEG data directories, installed-software review. Copies nothing. |

Both scripts emit `BF-<no>-windows-inventory*.json` (machine) and
`BF-<no>-windows-inventory*.md` (human).

## Why this directory and not a root `migration/windows/`

The requested layout was `migration/windows/`; this repository keeps every
operational script under `scripts/` (`scripts/{install,maintenance,diagnostics,recovery,migration}`),
so the tooling lives in `scripts/migration/windows/`. The deviation is
deliberate and documented in:

- `migration/README.md` (repo root) — pointer file kept at the expected location
- `docs/32-REPOSITORY-AUDIT-AND-CONFLICTS.md` §B-6 — audit entry for the name and location deviation

Filename deviation from the original request (kept, not "fixed", to preserve
repository consistency). No wrapper scripts are added on purpose: the static
test `tests/check-migration-static.sh` requires **every** `*.ps1` in this
directory to carry the dealer-id/JSON/Markdown/`-NoSoftware` contract, so thin
renamed wrappers would only duplicate the same contract in four files.

| Requested filename | Repo artifact | Status |
|---|---|---|
| `bf-win-inventory.ps1` | `BF-WindowsPreMigrationInventory.ps1` — identity/hardware/OS/disk blocks | Implemented under the repo name |
| `bf-win-network-export.ps1` | same script, `network` + `serial_ports` + `usb` sections | Merged, no separate file |
| `bf-win-software-export.ps1` | same script, `installed_software` / `services` / `scheduled_tasks` / `drivers` / `docker` / `vpn` / `remote_access` / `meg` sections (skippable with `-NoSoftware`) | Merged, no separate file |
| `bf-win-device-export.ps1` | `BF-WindowsDataExport.ps1` (`BF-<no>-windows-inventory-export.json/.md`) | Implemented under the repo name |

This mapping table is the authoritative name/deviation record: one inventory
report and one export manifest, not four fragmented scripts.

## How to run

PowerShell 5.1 (Windows PowerShell) and PowerShell 7+ are both supported. The
scripts are UTF-8 **with BOM** so Windows PowerShell 5.1 reads the Turkish
report headers correctly.

```powershell
# 1) Dry run first: prints the plan and the output paths, writes nothing.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\BF-WindowsPreMigrationInventory.ps1 `
    -DealerId 12010193 -OutputDirectory C:\Blueforce\migration -Check

# 2) Real read-only collection (dealer number known).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\BF-WindowsPreMigrationInventory.ps1 `
    -DealerId 12010193 -OutputDirectory C:\Blueforce\migration

# 3) Data-export review manifest (metadata only).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\BF-WindowsDataExport.ps1 `
    -DealerId 12010193 -OutputDirectory C:\Blueforce\migration

# 4) Privacy-reduced run: skip the software surface.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\BF-WindowsPreMigrationInventory.ps1 `
    -DealerId 12010193 -OutputDirectory C:\Blueforce\migration -NoSoftware
```

### Execution policy

`-ExecutionPolicy Bypass` applies to **that one process only**; it does not
change the machine or user execution policy. If the operator cannot use it,
either unblock the files (`Unblock-File .\BF-*.ps1`) or run from an already
permitted location/policy. Elevation is not required: nothing is changed, and
an unelevated run only reports which CIM sections were incomplete (the `notes`
array).

### Dealer number unknown

The report name comes from the **8-digit dealer number** (`^[0-9]{8}$`), never
from the machine hostname. If the dealer number is genuinely not known yet, use
the explicit opt-in:

```powershell
.\BF-WindowsPreMigrationInventory.ps1 -DealerIdUnknown -OutputDirectory C:\Blueforce\migration
```

That writes `BF-unknown-windows-inventory.*`, sets `dealer_id_known: false` and
adds a prominent warning in `notes` and at the top of the Markdown report: the
file **must not** be uploaded to the central inventory until the dealer number
is confirmed and the script is re-run with `-DealerId`. Do not guess a dealer
number to "fix" the filename.

## Output contract

| Item | Value |
|---|---|
| JSON | `<OutputDirectory>/BF-<no>-windows-inventory.json` |
| Markdown | `<OutputDirectory>/BF-<no>-windows-inventory.md` |
| Export JSON/MD | `<OutputDirectory>/BF-<no>-windows-inventory-export.{json,md}` |
| Device ID | `BF-<no>` (from the dealer number) |
| `report_type` | `windows-pre-migration-inventory` (export manifest: `windows-pre-migration-data-export-manifest`) |
| `read_only` | `true` — always; the run performs no state change |
| `dealer_id_known` | `true`, or `false` on an explicit `-DealerIdUnknown` run |
| `current_hostname` | the existing Windows hostname (unchanged, recorded) |
| `target_hostname` | `bf-<no>` — the hostname expected after migration (docs/02) |
| `schema_version` | `1` |

Field names are aligned with `scripts/diagnostics/bf-hardware-inventory.sh`
(docs/02 §9) so central tooling can consume both:

| `bf-hardware-inventory.sh` (Linux) | `BF-WindowsPreMigrationInventory.ps1` (Windows) |
|---|---|
| `schema_version`, `device_id`, `hostname`, `dealer_id`, `collected_at`, `notes` | same names (`collected_at` + `collected_at_utc`, `notes` is an array) |
| `manufacturer`, `model`, `serial` | same |
| `bios{vendor,version,date}` | same (+ `smbios_version`) |
| `cpu{model,cores,arch}` | same (+ `logical_processors`, `address_width`) |
| `memory_mb` | same |
| `disks` | per-disk objects `{name,size_gb,interface_type,media_type,serial}` (doc 02 §9 shape) |
| `network{interfaces,macs}` | `network.interfaces[]` (per-adapter objects) + `network.macs[]`, plus `ipv4_addresses`, `default_gateways`, `dns_servers`, `routes`, `network_profiles`, `proxy` |
| `gpu{model}` | same (+ `driver_version`, `video_processor`, `adapter_ram_mb`) |
| `usb` | `usb{devices[],controllers[]}` (includes USB hardware IDs `USB\VID_xxxx&PID_xxxx`) |
| `serial_ports` | `serial_ports{cim_serial_ports[],registry_devicemap,pnp_com_devices[]}` (COM ports) |
| `os{distro,kernel}` | `os{distro,version,build}` + a `windows{}` block (edition, DisplayVersion, build/UBR, hotfixes) |
| `smart`, `tpm`, `virt`, `temps` | not applicable on Windows; not emitted |
| — | Windows-only blocks: `windows`, `volumes`, `drivers`, `installed_software`, `services`, `scheduled_tasks`, `docker`, `vpn`, `remote_access`, `meg`, `user_profiles`, `collection_scope` |

## Read-only guarantee

Asserted mechanically by `tests/check-migration-static.sh` on every run:

- **Forbidden primitives** — no `Set-*`/`New-*`/`Remove-*` item or property
  cmdlet, no service control cmdlet, no network-configuration command of any
  kind, no registry write, no download cmdlet, no external process execution
  (the exact forbidden families are enumerated in
  `tests/check-migration-static.sh`). The only write is the report pair under
  `-OutputDirectory` (and `-Check` writes nothing at all).
- **Never collected** — credentials, passwords, tokens, private keys, DPAPI
  blobs, file contents, browser profiles, event logs, `Windows ProductId`.
- **Device IDs only** — RustDesk/AnyDesk: exactly one ID value is extracted
  (registry value named `id` / `ad.anynet.id`, else the matching one-line value
  in `RustDesk.toml` / `system.conf`). The RustDesk `id_ed25519` private key,
  AnyDesk password/hash settings and `*.ovpn`/`*.conf.dpapi` contents are never
  read — VPN tunnel/profile files are listed **by name only**.
- **Registry is read-only** — `Get-ItemProperty`/`Get-ChildItem` only, and
  path-like values are selected by an exact name allow-list so unrelated
  (possibly sensitive) values in the same key are ignored.
- **Software surface is opt-out** — `-NoSoftware` skips installed software,
  services, scheduled tasks and drivers; hardware, network, device and MEG-path
  sections are still collected.
- **Dry run** — `-Check` prints the plan and output paths, writes nothing,
  exits `0`.

## Verification status (honest note)

There is no PowerShell interpreter on the Linux build host, so these scripts are
statically verified only: syntax/structure review, the `tests/check-migration-static.sh`
contract (tag names, dealer-id regex, JSON/Markdown output, forbidden-primitive
greps) and brace/quote balance checking. **They have not been executed on a real
Windows terminal yet** — first execution belongs to the LAB/pilot step in
docs/28 §10 (`bf-hardware-inventory.sh` runs after migration and its JSON is
diffed against this report). Treat the first run output as unvalidated until
that LAB step is recorded.

## Related documentation

- `docs/28-WINDOWS-TO-LINUX-MIGRATION.md` — migration gate, test plan, rollback
- `docs/02-DEVICE-NAMING-AND-INVENTORY.md` — `BF-<no>` identity + JSON contract
- `docs/17-BACKUP-RECOVERY-AND-REINSTALL.md` — L8 reimage / recovery ladder
- `scripts/diagnostics/bf-live-hw-check` — read-only hardware gate used **after**
  migration on the Linux side
- `migration/README.md` (repo root) — location pointer
