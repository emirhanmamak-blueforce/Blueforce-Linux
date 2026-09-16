#!/usr/bin/env bash
# Validate migration tooling safety without PowerShell, QEMU, disks, or network access.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0

fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=1; }
pass() { printf 'OK: %s\n' "$*"; }
require_file() { [[ -f "$1" ]] && pass "present: ${1#$REPO_ROOT/}" || fail "missing: ${1#$REPO_ROOT/}"; }

WINDOWS_DIR="$REPO_ROOT/scripts/migration/windows"
ANYDESK="$REPO_ROOT/scripts/install/optional/anydesk/install-anydesk.sh"
HW_CHECK="$REPO_ROOT/scripts/diagnostics/bf-live-hw-check"
QEMU_PLAN="$REPO_ROOT/tests/qemu-field-os-test-plan.md"

require_file "$WINDOWS_DIR/BF-WindowsPreMigrationInventory.ps1"
require_file "$WINDOWS_DIR/BF-WindowsDataExport.ps1"
require_file "$ANYDESK"
require_file "$HW_CHECK"
require_file "$QEMU_PLAN"

for script in "$WINDOWS_DIR"/*.ps1; do
  [[ -f "$script" ]] || continue
  grep -Fq "[ValidatePattern('^[0-9]{8}$')]" "$script" || fail "8-digit DealerId validation missing: ${script#$REPO_ROOT/}"
  grep -Fq '[string]$OutputDirectory' "$script" || fail "OutputDirectory parameter missing: ${script#$REPO_ROOT/}"
  grep -q 'BF-$DealerId-windows-inventory' "$script" || fail "required BF output basename missing: ${script#$REPO_ROOT/}"
  grep -qi 'ConvertTo-Json' "$script" || fail "JSON output missing: ${script#$REPO_ROOT/}"
  grep -q 'Markdown' "$script" || fail "Markdown output missing: ${script#$REPO_ROOT/}"
  # Turkish report headers need a UTF-8 BOM so Windows PowerShell 5.1 parses the file correctly.
  [[ "$(head -c 3 "$script" | od -An -tx1 | tr -d ' \n')" == 'efbbbf' ]] || fail "UTF-8 BOM missing (Windows PowerShell 5.1 compatibility): ${script#$REPO_ROOT/}"
done

grep -q -- '-NoSoftware' "$WINDOWS_DIR/BF-WindowsPreMigrationInventory.ps1" || fail 'inventory must support -NoSoftware'
grep -q -- '-NoSoftware' "$WINDOWS_DIR/BF-WindowsDataExport.ps1" || fail 'export must support -NoSoftware'

# Migration scripts are inventory/export only: no credential APIs, writes, service/network/registry mutation, or downloads.
if grep -RniE '(Get-Credential|CredentialManager|Windows\.Security\.Credentials|cmdkey|vaultcmd|ConvertTo-SecureString|Read-Host.*password)' "$WINDOWS_DIR"; then
  fail 'credential API or password collection found in Windows migration scripts'
else
  pass 'no credential API or password collection in Windows scripts'
fi
if grep -RniE '(Set-Service|Start-Service|Stop-Service|Restart-Service|New-Net|Set-Net|Remove-Net|Disable-Net|Enable-Net|netsh|Set-ItemProperty|New-ItemProperty|Remove-ItemProperty|reg(\.exe)?[[:space:]]+(add|delete)|Invoke-WebRequest|curl|wget|Start-BitsTransfer)' "$WINDOWS_DIR"; then
  fail 'forbidden mutation or download primitive found in Windows migration scripts'
else
  pass 'Windows scripts have no mutation or download primitive'
fi

# The export manifest must stay metadata-only: no copy, move, archive or delete primitive.
if grep -RniE '(Copy-Item|Move-Item|Remove-Item|Compress-Archive|Expand-Archive|robocopy|xcopy)' "$WINDOWS_DIR"/*.ps1; then
  fail 'copy/move/archive/delete primitive found in Windows migration scripts'
else
  pass 'Windows scripts have no copy/move/archive/delete primitive'
fi

# ---------------------------------------------------------------------------
# Migration scope: every section the migration brief requires must be present,
# still read-only, and still named from the dealer number (not the hostname).
# ---------------------------------------------------------------------------
INVENTORY="$WINDOWS_DIR/BF-WindowsPreMigrationInventory.ps1"
EXPORT="$WINDOWS_DIR/BF-WindowsDataExport.ps1"
WINDOWS_README="$WINDOWS_DIR/README.md"
MIGRATION_POINTER="$REPO_ROOT/migration/README.md"

require_file "$INVENTORY"
require_file "$EXPORT"
require_file "$WINDOWS_README"
require_file "$MIGRATION_POINTER"

require_marker() { grep -Fq "$2" "$1" || fail "missing '$2' in ${1#$REPO_ROOT/}"; }

# Network scope: IP config, DNS, gateway(s), routes, profiles, proxy.
for marker in 'Win32_NetworkAdapterConfiguration' 'DNSServerSearchOrder' 'DefaultIPGateway' \
              'Win32_IP4RouteTable' 'default_gateways' 'network_profiles' 'ProxyServer'; do
  require_marker "$INVENTORY" "$marker"
done
# Software scope: installed software, services, scheduled tasks, drivers, Windows version.
for marker in 'installed_software' 'Win32_Service' 'Get-ScheduledTask' 'Win32_PnPSignedDriver' \
              "'DisplayVersion'" 'Win32_QuickFixEngineering' "'UBR'"; do
  require_marker "$INVENTORY" "$marker"
done
# Device scope: COM/serial ports, USB hardware IDs.
for marker in 'Win32_SerialPort' 'SERIALCOMM' 'hardware_id' 'Win32_USBController'; do
  require_marker "$INVENTORY" "$marker"
done
# Migration-critical applications: Docker, VPN clients, remote-access IDs, MEG paths.
for marker in 'com.docker.service' 'WireGuard' 'OpenVPN' 'conf.dpapi' '.ovpn' \
              'rustdesk_id' 'anydesk_id' 'Get-MegSnapshot' 'registry_paths'; do
  require_marker "$INVENTORY" "$marker"
done
# Identity: dealer-number naming, existing hostname recorded, target hostname.
for marker in 'current_hostname' 'target_hostname' 'dealer_id_known' 'READ-ONLY CONTRACT' \
              'DealerIdUnknown' 'WARNING: dealer number unknown' 'executed_external_tools'; do
  require_marker "$INVENTORY" "$marker"
done
# Secrets stay out of scope, including the RustDesk private key file.
for marker in 'id_ed25519' 'private keys' 'Windows ProductId'; do
  require_marker "$INVENTORY" "$marker"
done
grep -Fq -- '-Check' "$INVENTORY" || fail 'inventory must support -Check (read-only dry run)'
grep -Fq -- '-Check' "$EXPORT" || fail 'export must support -Check (read-only dry run)'

# Export manifest stays metadata-only and review-gated.
for marker in 'windows-pre-migration-data-export-manifest' 'candidate_folders' 'removable_media_roots' \
              'mapped_network_drives' 'Win32_NetworkConnection' 'Win32_Printer' 'meg_data_directories' \
              'copies_performed' 'manual-copy-after-owner-approval' 'READ-ONLY CONTRACT' 'DealerIdUnknown'; do
  require_marker "$EXPORT" "$marker"
done

# Requested-name -> repo-name deviation must stay documented (docs/32 B-6).
for marker in 'bf-win-inventory.ps1' 'bf-win-network-export.ps1' 'bf-win-software-export.ps1' \
              'bf-win-device-export.ps1' 'BF-WindowsPreMigrationInventory.ps1' 'BF-WindowsDataExport.ps1' \
              'ExecutionPolicy' 'scripts/migration/windows' 'read-only'; do
  require_marker "$WINDOWS_README" "$marker"
done
grep -Fq 'scripts/migration/windows' "$MIGRATION_POINTER" || fail 'migration/README.md must point at scripts/migration/windows'
grep -Fq 'docs/32' "$MIGRATION_POINTER" || fail 'migration/README.md must reference the docs/32 audit entry'
grep -Fiq 'migration/windows' "$MIGRATION_POINTER" || fail 'migration/README.md must name the requested migration/windows path'
pass 'migration scope, naming and location deviations are documented and asserted'

[[ "$(head -n 1 "$ANYDESK")" == '#!/usr/bin/env bash' ]] || fail 'AnyDesk skeleton requires Bash shebang'
grep -q '^set -euo pipefail$' "$ANYDESK" || fail 'AnyDesk skeleton requires strict mode'
bash -n "$ANYDESK" && pass 'AnyDesk skeleton parses' || fail 'AnyDesk skeleton parse error'
grep -q 'ANYDESK_LICENSE_CONFIRMED=true' "$ANYDESK" || fail 'AnyDesk license confirmation gate missing'
if grep -niE '(curl|wget|apt(-get)?[[:space:]].*install|dnf[[:space:]].*install|zypper[[:space:]].*install|license(_|[[:space:]])?(key|file)|[A-Z0-9]{4}(-[A-Z0-9]{4}){3,})' "$ANYDESK"; then
  fail 'AnyDesk skeleton must not download, install, or embed a license'
else
  pass 'AnyDesk skeleton has no download, install, or embedded license'
fi

grep -q '^#!/usr/bin/env bash' "$HW_CHECK" || fail 'hardware check requires Bash shebang'
grep -q '^set -euo pipefail$' "$HW_CHECK" || fail 'hardware check requires strict mode'
bash -n "$HW_CHECK" && pass 'hardware check parses' || fail 'hardware check parse error'
grep -q -- '--json' "$HW_CHECK" || fail 'hardware check --json missing'
grep -q -- '--markdown' "$HW_CHECK" || fail 'hardware check --markdown missing'
for verdict in SUPPORTED WARNING BLOCKED; do grep -q "$verdict" "$HW_CHECK" || fail "hardware verdict missing: $verdict"; done
# Every check the migration gate relies on must be present in the JSON payload.
for hwcheck in architecture ram disk disk_type smart nic nic_link serial usb boot_mode secure_boot tpm virt cpu_virt; do
  grep -Fq "\"name\":\"$hwcheck\"" "$HW_CHECK" || fail "hardware check missing: $hwcheck"
done
# Verdict thresholds must be documented in the output, not just implied by code.
grep -Fq '| Kontrol | BLOCKED | WARNING | SUPPORTED |' "$HW_CHECK" || fail 'hardware check threshold table missing from markdown output'
for threshold in '68719476736' '2048' '4096' '64 GiB' '4096 MiB' 'vmx/svm'; do
  grep -Fq -- "$threshold" "$HW_CHECK" || fail "hardware threshold not documented: $threshold"
done
pass 'hardware check covers arch/ram/disk/media/smart/nic/link/serial/usb/boot/secure-boot/tpm/virt and documents thresholds'
if grep -niE '(apt(-get)?[[:space:]].*install|dnf[[:space:]].*install|zypper[[:space:]].*install|mkfs|wipefs|dd[[:space:]].*of=|rm[[:space:]]+-rf|systemctl[[:space:]]+(start|stop|restart|enable|disable)|ip[[:space:]]+(link|addr|route)[[:space:]]+(add|del|set)|nmcli[[:space:]].*(up|down|modify))' "$HW_CHECK"; then
  fail 'hardware check must not install, wipe, alter services, or alter networking'
else
  pass 'hardware check is non-mutating by static pattern'
fi

for test_id in $(seq 1 18); do
  grep -q "T${test_id}" "$QEMU_PLAN" || fail "QEMU/LAB plan missing T${test_id}"
done
grep -qiE 'CI.*statik|statik.*CI' "$QEMU_PLAN" || fail 'QEMU/LAB plan must distinguish CI/static coverage'
grep -qiE 'QEMU|KVM' "$QEMU_PLAN" || fail 'QEMU/LAB plan must cover QEMU/KVM'

if [[ "$FAIL" -ne 0 ]]; then
  printf 'check-migration-static: FAILED\n' >&2
  exit 1
fi
printf 'check-migration-static: all passed\n'
