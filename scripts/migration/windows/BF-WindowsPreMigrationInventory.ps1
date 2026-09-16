<#
.SYNOPSIS
  Read-only Windows pre-migration inventory for one Blueforce dealer.
.DESCRIPTION
  Collects the full pre-migration picture of a Windows field terminal:
  hardware, Windows version, disks/volumes, network (adapters, IP addresses,
  DNS, gateways, routes, network profiles, proxy), serial/COM ports, USB
  devices and hardware IDs, drivers, installed software, services, scheduled
  tasks, Docker presence, VPN clients (WireGuard/OpenVPN/other), RustDesk and
  AnyDesk device IDs, MEG application/service/configuration paths, and the
  current Windows hostname.

  READ-ONLY CONTRACT (asserted by tests/check-migration-static.sh):
    * No Set-*, New-*, Remove-* cmdlets, no service control, no network
      configuration command, no registry write, no download.
    * No credential, password, token or private key is collected.
    * The registry is only ever read (Get-ItemProperty / Get-ChildItem).
    * RustDesk/AnyDesk: only the numeric device ID value is extracted. The
      RustDesk id_ed25519 private key and the contents of *.conf, *.ovpn and
      *.dpapi files are never read - only their file names are listed.
    * No external tool is executed (docker.exe included); all data comes from
      CIM, the registry and file/directory metadata.
    * The only writes are the JSON and Markdown reports under
      -OutputDirectory; with -Check nothing is written at all.

  Output contract: BF-<no>-windows-inventory.json and
  BF-<no>-windows-inventory.md, where <no> is the 8-digit dealer number - not
  the hostname of the machine being inventoried.
.PARAMETER DealerId
  8-digit Blueforce dealer number (^[0-9]{8}$). Device ID becomes BF-<no>.
.PARAMETER DealerIdUnknown
  Explicit opt-in for a device whose dealer number is not known yet. The report
  is written as BF-unknown-windows-inventory.* and carries a prominent warning:
  it must not be uploaded to the central inventory until the dealer number is
  confirmed and the script is re-run with -DealerId.
.PARAMETER OutputDirectory
  Directory that receives BF-<no>-windows-inventory.json and .md.
.PARAMETER NoSoftware
  Skip the software surface (installed software, services, scheduled tasks,
  drivers). Hardware, network, device and MEG-path sections are still collected.
.PARAMETER Check
  Dry run: validate parameters, print the collection plan and the resolved
  output paths, write nothing, exit 0.
.EXAMPLE
  .\BF-WindowsPreMigrationInventory.ps1 -DealerId 12010193 -OutputDirectory C:\Blueforce\migration
.EXAMPLE
  .\BF-WindowsPreMigrationInventory.ps1 -DealerIdUnknown -OutputDirectory C:\Blueforce\migration
.EXAMPLE
  .\BF-WindowsPreMigrationInventory.ps1 -DealerId 12010193 -OutputDirectory C:\Blueforce\migration -Check
.NOTES
  Elevation is not required and nothing is changed. Some CIM sections can be
  incomplete when the script runs unelevated; that is reported in "notes".
#>
[CmdletBinding(DefaultParameterSetName = 'KnownDealer')]
param(
    [Parameter(Mandatory, ParameterSetName = 'KnownDealer')]
    [ValidatePattern('^[0-9]{8}$')]
    [string]$DealerId,

    [Parameter(Mandatory, ParameterSetName = 'UnknownDealer')]
    [switch]$DealerIdUnknown,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory,

    [switch]$NoSoftware,

    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-SafeValue {
    param([object]$Value)
    if ($null -eq $Value) { return 'unknown' }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return 'unknown' }
    return $text
}

function ConvertTo-MarkdownCell {
    param([object]$Value)
    return ((Get-SafeValue $Value) -replace '\|', '\|' -replace "`r?`n", '; ')
}

function ConvertTo-Gigabytes {
    param([object]$Bytes)
    if ($null -eq $Bytes) { return 'unknown' }
    return [math]::Round(([double]$Bytes) / 1GB, 2)
}

function ConvertTo-Megabytes {
    param([object]$Bytes)
    if ($null -eq $Bytes) { return 'unknown' }
    return [long][math]::Round(([double]$Bytes) / 1MB)
}

function ConvertTo-IsoUtc {
    param([object]$Value)
    if ($null -eq $Value) { return 'unknown' }
    try { return ([datetime]$Value).ToUniversalTime().ToString('o') } catch { return 'unknown' }
}

# Null-safe property read for CIM/WMI objects, so a missing class or a failed
# probe degrades to $null/'unknown' instead of aborting the report.
function Get-ObjectValue {
    param([object]$InputObject, [string]$Name)
    if ($null -eq $InputObject) { return $null }
    $prop = $InputObject.PSObject.Properties | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Get-ProgramFilesRoots {
    $roots = @()
    if ($env:ProgramFiles) { $roots += $env:ProgramFiles }
    if (${env:ProgramFiles(x86)}) { $roots += ${env:ProgramFiles(x86)} }
    if ($env:ProgramData) { $roots += $env:ProgramData }
    $roots += 'C:\'
    return @($roots | Select-Object -Unique)
}

# Reads named values from a registry key. Read-only; missing values stay
# 'unknown' and never abort the report.
function Get-RegistryValues {
    param([string]$Path, [string[]]$Names)
    $result = [ordered]@{}
    foreach ($name in $Names) { $result[$name] = 'unknown' }
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    $props = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $props) { return $result }
    foreach ($name in $Names) {
        $prop = $props.PSObject.Properties | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if ($null -ne $prop) { $result[$name] = Get-SafeValue $prop.Value }
    }
    return $result
}

# Reads only the registry values whose NAME matches an exact allow-list
# pattern. Used to pick up path-like settings without ever touching
# credential/secret values that live in the same key.
function Get-RegistryValuesByNamePattern {
    param([string]$Path, [string]$NamePattern)
    $result = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    $props = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $props) { return $result }
    foreach ($prop in $props.PSObject.Properties) {
        if ($prop.Name -match $NamePattern) { $result[$prop.Name] = Get-SafeValue $prop.Value }
    }
    return $result
}

# Extracts a single captured value from one line of a configuration file.
# The file content is never returned, stored or reported - only the capture
# group. This helper is NEVER called on key material (RustDesk id_ed25519,
# *.ovpn, *.dpapi).
function Get-ConfigFileValue {
    param([string]$Path, [string]$LinePattern, [string]$CapturePattern)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'not-found' }
    $hit = Select-String -LiteralPath $Path -Pattern $LinePattern -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $hit) { return 'not-found' }
    if ($hit.Line -match $CapturePattern) { return (Get-SafeValue $Matches[1]) }
    return 'not-found'
}

function Get-FileVersionInfo {
    param([string]$Path)
    if (-not $Path) { return 'unknown' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'not-found' }
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $item) { return 'unknown' }
    if ($null -eq $item.VersionInfo) { return 'unknown' }
    return (Get-SafeValue $item.VersionInfo.FileVersion)
}

# Directory metadata (path + mtime) only; no file contents.
function Get-DirectoryReport {
    param([string]$Root, [string]$Filter)
    if ([string]::IsNullOrWhiteSpace($Root)) { return @() }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $Root -Directory -Filter $Filter -ErrorAction SilentlyContinue |
        ForEach-Object {
            [ordered]@{
                path = $_.FullName
                last_write_utc = ConvertTo-IsoUtc $_.LastWriteTimeUtc
                review_required = $true
            }
        })
}

# File NAMES only for review lists such as VPN tunnel configs (contents are
# credentials/keys and are deliberately never read).
function Get-FileNameReport {
    param([string[]]$Roots, [string]$Filter)
    $out = @()
    foreach ($root in $Roots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $out += @(Get-ChildItem -LiteralPath $root -File -Filter $Filter -ErrorAction SilentlyContinue |
            ForEach-Object {
                [ordered]@{
                    name = $_.Name
                    path = $_.FullName
                    last_write_utc = ConvertTo-IsoUtc $_.LastWriteTimeUtc
                    contents_read = $false
                }
            })
    }
    return @($out)
}

function Get-NamesOf {
    param([object[]]$Items)
    return @($Items | ForEach-Object { $_['name'] })
}

function Get-InstalledSoftware {
    $uninstallPaths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $items = Get-ItemProperty -Path $uninstallPaths -ErrorAction SilentlyContinue |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.DisplayName) } |
        ForEach-Object {
            [ordered]@{
                name = Get-SafeValue $_.DisplayName
                version = Get-SafeValue $_.DisplayVersion
                publisher = Get-SafeValue $_.Publisher
                install_date = Get-SafeValue $_.InstallDate
                install_location = Get-SafeValue $_.InstallLocation
            }
        }
    return @($items | Sort-Object -Property { $_['name'] })
}

# Running services, auto-start services that are NOT running (a migration
# signal), and the subset relevant to remote access / Docker / VPN / MEG.
function Get-ServiceSnapshot {
    $watchlist = '(?i)docker|wireguard|openvpn|rustdesk|anydesk|mesh|meg|blueforce|teamviewer|tailscale|zerotier|forti|anyconnect|globalprotect|vpn'
    $rows = @(Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue | ForEach-Object {
        [ordered]@{
            name = Get-SafeValue $_.Name
            display_name = Get-SafeValue $_.DisplayName
            state = Get-SafeValue $_.State
            start_mode = Get-SafeValue $_.StartMode
            start_name = Get-SafeValue $_.StartName
            path = Get-SafeValue $_.PathName
        }
    })
    $running = @($rows | Where-Object { $_['state'] -eq 'Running' } | Sort-Object -Property { $_['name'] })
    $stoppedAuto = @($rows | Where-Object { $_['state'] -eq 'Stopped' -and $_['start_mode'] -eq 'Auto' } | Sort-Object -Property { $_['name'] })
    $relevant = @($rows | Where-Object { ($_['name'] + ' ' + $_['display_name']) -match $watchlist } | Sort-Object -Property { $_['name'] })
    return [ordered]@{
        total_services = $rows.Count
        selection = 'running + auto-start-but-stopped + migration-relevant; a dump of every stopped/disabled service is intentionally omitted to keep the report bounded'
        running = $running
        auto_start_but_stopped = $stoppedAuto
        relevant_to_migration = $relevant
    }
}

# Non-Microsoft scheduled tasks (vendor tasks) plus the migration-relevant
# subset. Uses the ScheduledTasks module only; no other execution path.
function Get-ScheduledTaskSnapshot {
    $watchlist = '(?i)docker|meg|blueforce|vpn|wireguard|openvpn|rustdesk|anydesk|mesh|backup|veeam|acronis'
    $tasks = @()
    try {
        $tasks = @(Get-ScheduledTask -ErrorAction Stop |
            Where-Object { $_.TaskPath -notlike '\Microsoft\*' } |
            ForEach-Object {
                [ordered]@{
                    task_path = Get-SafeValue $_.TaskPath
                    task_name = Get-SafeValue $_.TaskName
                    state = Get-SafeValue ([string]$_.State)
                    author = Get-SafeValue $_.Author
                    run_as_user = Get-SafeValue $_.Principal.UserId
                }
            })
    } catch {
        return [ordered]@{
            available = $false
            note = 'Get-ScheduledTask unavailable on this host; scheduled-task enumeration skipped (no other tool is invoked).'
            total = 0
            items = @()
            relevant_to_migration = @()
        }
    }
    $items = @($tasks | Sort-Object -Property { $_['task_path'] + $_['task_name'] })
    return [ordered]@{
        available = $true
        note = 'Non-Microsoft task paths only.'
        total = $items.Count
        items = $items
        relevant_to_migration = @($items | Where-Object { ($_['task_path'] + $_['task_name']) -match $watchlist })
    }
}

# COM/serial ports from three read-only sources: CIM, the SERIALCOMM device
# map, and PnP entities whose friendly name carries a (COMx) suffix.
function Get-ComPortSnapshot {
    $cimPorts = @(Get-CimInstance -ClassName Win32_SerialPort -ErrorAction SilentlyContinue | ForEach-Object {
        [ordered]@{
            device_id = Get-SafeValue $_.DeviceID
            name = Get-SafeValue $_.Name
            description = Get-SafeValue $_.Description
            provider_type = Get-SafeValue $_.ProviderType
            pnp_device_id = Get-SafeValue $_.PNPDeviceID
        }
    })
    $deviceMap = [ordered]@{}
    if (Test-Path -LiteralPath 'HKLM:\HARDWARE\DEVICEMAP\SERIALCOMM') {
        $props = Get-ItemProperty -LiteralPath 'HKLM:\HARDWARE\DEVICEMAP\SERIALCOMM' -ErrorAction SilentlyContinue
        if ($null -ne $props) {
            foreach ($prop in $props.PSObject.Properties) {
                if ($prop.Name -like 'PS*') { continue }
                $deviceMap[$prop.Name] = Get-SafeValue $prop.Value
            }
        }
    }
    $pnpPorts = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*(COM*' } |
        ForEach-Object {
            [ordered]@{
                name = Get-SafeValue $_.Name
                device_id = Get-SafeValue $_.DeviceID
                status = Get-SafeValue $_.Status
            }
        })
    return [ordered]@{
        cim_serial_ports = $cimPorts
        registry_devicemap = $deviceMap
        pnp_com_devices = $pnpPorts
    }
}

# USB devices with their hardware IDs (VID_/PID_ live in DeviceID) plus the
# USB host controllers.
function Get-UsbSnapshot {
    $devices = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.DeviceID -like 'USB\*' -or $_.PNPClass -eq 'USB' } |
        ForEach-Object {
            [ordered]@{
                name = Get-SafeValue $_.Name
                description = Get-SafeValue $_.Description
                hardware_id = Get-SafeValue $_.DeviceID
                device_class = Get-SafeValue $_.PNPClass
                status = Get-SafeValue $_.Status
                service = Get-SafeValue $_.Service
            }
        })
    $controllers = @(Get-CimInstance -ClassName Win32_USBController -ErrorAction SilentlyContinue | ForEach-Object {
        [ordered]@{
            name = Get-SafeValue $_.Name
            device_id = Get-SafeValue $_.DeviceID
        }
    })
    return [ordered]@{
        devices = @($devices | Sort-Object -Property { $_['name'] })
        controllers = $controllers
    }
}

function Get-DriverSnapshot {
    $drivers = @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
        Where-Object { $_.DeviceName } |
        ForEach-Object {
            [ordered]@{
                device_name = Get-SafeValue $_.DeviceName
                device_class = Get-SafeValue $_.DeviceClass
                manufacturer = Get-SafeValue $_.Manufacturer
                driver_provider = Get-SafeValue $_.DriverProviderName
                driver_version = Get-SafeValue $_.DriverVersion
                driver_date = ConvertTo-IsoUtc $_.DriverDate
                inf_name = Get-SafeValue $_.InfName
            }
        })
    return [ordered]@{
        total = $drivers.Count
        items = @($drivers | Sort-Object -Property { $_['device_name'] })
    }
}

# Docker presence from install metadata and service state only. docker.exe is
# never executed: no engine contact, no image/build/container side effect.
function Get-DockerSnapshot {
    $roots = Get-ProgramFilesRoots
    $dockerCli = 'unknown'
    $cmd = Get-Command -Name 'docker.exe' -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { $dockerCli = Get-SafeValue (Get-ObjectValue $cmd 'Source') }

    $desktopApp = 'not-found'
    foreach ($root in $roots) {
        $candidate = Join-Path $root 'Docker\Docker\Docker Desktop.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $desktopApp = $candidate; break }
    }

    $service = $null
    $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='com.docker.service'" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $svc) {
        $service = [ordered]@{
            name = Get-SafeValue (Get-ObjectValue $svc 'Name')
            state = Get-SafeValue (Get-ObjectValue $svc 'State')
            start_mode = Get-SafeValue (Get-ObjectValue $svc 'StartMode')
        }
    }

    $wslDistros = @()
    if (Test-Path -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss') {
        $wslDistros = @(Get-ChildItem -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue |
            ForEach-Object {
                $props = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                if ($null -eq $props) { return }
                if (@($props.PSObject.Properties.Name) -contains 'DistributionName') {
                    Get-SafeValue $props.DistributionName
                }
            } | Where-Object { $_ })
    }

    $present = ($dockerCli -ne 'unknown') -or ($desktopApp -ne 'not-found') -or ($null -ne $service)
    return [ordered]@{
        present = [bool]$present
        docker_cli_path = $dockerCli
        docker_cli_file_version = Get-FileVersionInfo $dockerCli
        desktop_app_path = $desktopApp
        desktop_app_file_version = Get-FileVersionInfo $desktopApp
        service = $service
        wsl_distributions = @($wslDistros)
        note = 'Presence and file metadata only; the docker CLI is never executed.'
    }
}

# VPN clients: installed software matches, related services, tunnel/profile
# NAMES (contents of *.conf.dpapi and *.ovpn are credentials and are not read).
function Get-VpnSnapshot {
    param([object[]]$Software, [object[]]$Services)

    $softwarePattern = '(?i)(wireguard|openvpn|tailscale|zerotier|anyconnect|forticlient|globalprotect|softether|nordvpn|protonvpn|expressvpn|surfshark|windscribe)'
    $softwareMatches = @($Software | Where-Object { ($_['name'] + ' ' + $_['publisher']) -match $softwarePattern })
    $servicePattern = '(?i)wireguard|openvpn|tailscale|zerotier|anyconnect|forticlient|globalprotect|vpnagent'
    $serviceMatches = @($Services | Where-Object { ($_['name'] + ' ' + $_['display_name']) -match $servicePattern })

    $roots = Get-ProgramFilesRoots
    $wireguardDirs = @()
    $openVpnDirs = @()
    foreach ($root in $roots) {
        $wireguardDirs += (Join-Path $root 'WireGuard\Data\Configurations')
        $openVpnDirs += (Join-Path $root 'OpenVPN\config')
        $openVpnDirs += (Join-Path $root 'OpenVPN\config-auto')
    }

    $wireguardKeys = @()
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\WireGuard') {
        $wireguardKeys = @(Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\WireGuard' -ErrorAction SilentlyContinue |
            ForEach-Object { Get-SafeValue (Get-ObjectValue $_ 'Name') })
    }
    $wireguardTunnels = @(Get-FileNameReport -Roots $wireguardDirs -Filter '*.conf.dpapi')
    $openVpnProfiles = @(Get-FileNameReport -Roots $openVpnDirs -Filter '*.ovpn')

    $wireguardPresent = (@($softwareMatches | Where-Object { $_['name'] -match '(?i)wireguard' }).Count -gt 0) -or
        ($wireguardKeys.Count -gt 0) -or ($wireguardTunnels.Count -gt 0)
    $openVpnPresent = (@($softwareMatches | Where-Object { $_['name'] -match '(?i)openvpn' }).Count -gt 0) -or
        ($openVpnProfiles.Count -gt 0)

    return [ordered]@{
        wireguard = [ordered]@{
            present = [bool]$wireguardPresent
            registry_tunnels = $wireguardKeys
            tunnel_config_files = $wireguardTunnels
            contents_note = 'Tunnel configuration contents are never read; only file names are listed.'
        }
        openvpn = [ordered]@{
            present = [bool]$openVpnPresent
            profile_files = $openVpnProfiles
            registry_paths = Get-RegistryValuesByNamePattern -Path 'HKLM:\SOFTWARE\OpenVPN' -NamePattern '(?i)^(config_dir|config_auto|config|log_dir|exe_path|install_dir)$'
            contents_note = 'Profile contents (certificates/keys) are never read; only file names are listed.'
        }
        installed_vpn_software = $softwareMatches
        vpn_services = $serviceMatches
    }
}

# RustDesk / AnyDesk device IDs. Only the ID value is extracted: for RustDesk
# the registry value literally named 'id' or the id = ... line of
# RustDesk.toml; for AnyDesk the ad.anynet.id value. Private-key files
# (id_ed25519) and password/hash settings are never opened.
function Get-RemoteAccessSnapshot {
    param([object[]]$Services)

    $rustdeskId = 'not-found'
    foreach ($path in @('HKCU:\Software\RustDesk', 'HKLM:\Software\RustDesk', 'HKLM:\Software\WOW6432Node\RustDesk')) {
        if ($rustdeskId -ne 'not-found') { break }
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $props = Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue
        if ($null -eq $props) { continue }
        $idProp = $props.PSObject.Properties | Where-Object { $_.Name -eq 'id' } | Select-Object -First 1
        if ($null -ne $idProp) { $rustdeskId = Get-SafeValue $idProp.Value }
    }
    if ($rustdeskId -eq 'not-found' -and $env:APPDATA) {
        foreach ($file in @('RustDesk.toml', 'RustDesk2.toml')) {
            $value = Get-ConfigFileValue -Path (Join-Path $env:APPDATA "RustDesk\config\$file") `
                -LinePattern '^\s*id\s*=' -CapturePattern "id\s*=\s*'?([0-9A-Za-z]+)'?"
            if ($value -ne 'not-found') { $rustdeskId = $value; break }
        }
    }

    $anydeskId = 'not-found'
    foreach ($path in @('HKLM:\Software\AnyDesk', 'HKCU:\Software\AnyDesk', 'HKLM:\Software\WOW6432Node\AnyDesk')) {
        if ($anydeskId -ne 'not-found') { break }
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $props = Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue
        if ($null -eq $props) { continue }
        $idProp = $props.PSObject.Properties |
            Where-Object { $_.Name -match '(?i)^ad\.anynet\.id$|^anynet[._]?id$|^client[._]?id$' } |
            Select-Object -First 1
        if ($null -ne $idProp) { $anydeskId = Get-SafeValue $idProp.Value }
    }
    if ($anydeskId -eq 'not-found') {
        $confFiles = @()
        if ($env:ProgramData) { $confFiles += (Join-Path $env:ProgramData 'AnyDesk\system.conf') }
        if ($env:APPDATA) { $confFiles += (Join-Path $env:APPDATA 'AnyDesk\user.conf') }
        foreach ($file in $confFiles) {
            $value = Get-ConfigFileValue -Path $file `
                -LinePattern '^\s*ad\.anynet\.id\s*=' -CapturePattern 'ad\.anynet\.id\s*=\s*([0-9A-Za-z]+)'
            if ($value -ne 'not-found') { $anydeskId = $value; break }
        }
    }

    $servicePattern = '(?i)rustdesk|anydesk|mesh|teamviewer'
    return [ordered]@{
        rustdesk_id = $rustdeskId
        anydesk_id = $anydeskId
        rustdesk_id_source = 'registry value named id, else the id line of RustDesk.toml (the id_ed25519 private key is never read)'
        anydesk_id_source = 'registry ad.anynet.id, else the ad.anynet.id line of system.conf/user.conf (password/hash settings are never read)'
        remote_access_services = @($Services | Where-Object { ($_['name'] + ' ' + $_['display_name']) -match $servicePattern })
    }
}

# MEG application/service/configuration paths. Directory and registry key
# NAMES plus path-like registry values only; no directory contents, no
# arbitrary registry values.
function Get-MegSnapshot {
    param([object[]]$Software, [object[]]$Services, [string[]]$Roots)

    $megPattern = '(?i)\bmeg\b'
    $softwareMatches = @($Software | Where-Object { ($_['name'] + ' ' + $_['publisher']) -match $megPattern })
    $serviceMatches = @($Services | Where-Object { ($_['name'] + ' ' + $_['display_name']) -match $megPattern })

    $directories = @()
    foreach ($root in $Roots) { $directories += @(Get-DirectoryReport -Root $root -Filter '*MEG*') }

    $registryKeys = @()
    foreach ($base in @('HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node', 'HKCU:\Software')) {
        if (-not (Test-Path -LiteralPath $base)) { continue }
        $registryKeys += @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match $megPattern } |
            ForEach-Object { Get-SafeValue $_.Name })
    }
    $registryKeys = @($registryKeys | Where-Object { $_ -ne 'unknown' } | Select-Object -Unique)

    $registryPaths = [ordered]@{}
    foreach ($key in $registryKeys) {
        # Registry key names come back as HKEY_LOCAL_MACHINE\...; map them to
        # the PowerShell drive form before reading.
        $readPath = $key -replace '^HKEY_LOCAL_MACHINE', 'HKLM:' -replace '^HKEY_CURRENT_USER', 'HKCU:'
        $registryPaths[$key] = Get-RegistryValuesByNamePattern -Path $readPath `
            -NamePattern '(?i)^(install(path|dir)?|config(path|dir)?|data(path|dir)?|app(path|dir)?|exe(path)?|program(path|dir)?)$'
    }

    $installLocations = @($softwareMatches | ForEach-Object { $_['install_location'] } | Where-Object { $_ -ne 'unknown' })

    return [ordered]@{
        software = @($softwareMatches)
        services = @($serviceMatches)
        config_directories = @($directories)
        registry_keys = @($registryKeys)
        registry_paths = $registryPaths
        install_locations = @($installLocations)
        note = 'Directory and registry key names plus path-like values only; no file contents and no arbitrary registry values.'
    }
}

function Get-NetworkSnapshot {
    $configs = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction SilentlyContinue |
        ForEach-Object {
            $addresses = @($_.IPAddress | Where-Object { $_ })
            [ordered]@{
                description = Get-SafeValue $_.Description
                mac_address = Get-SafeValue $_.MACAddress
                dhcp_enabled = [bool]$_.DHCPEnabled
                dhcp_server = Get-SafeValue $_.DHCPServer
                ipv4_addresses = @($addresses | Where-Object { $_ -match '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' })
                ipv6_addresses = @($addresses | Where-Object { $_ -match ':' })
                subnet_masks = @($_.IPSubnet | Where-Object { $_ })
                default_gateways = @($_.DefaultIPGateway | Where-Object { $_ })
                dns_servers = @($_.DNSServerSearchOrder | Where-Object { $_ })
                dns_domain = Get-SafeValue $_.DNSDomain
                dns_hostname = Get-SafeValue $_.DNSHostName
            }
        })

    $routes = @(Get-CimInstance -ClassName Win32_IP4RouteTable -ErrorAction SilentlyContinue |
        ForEach-Object {
            [ordered]@{
                destination = Get-SafeValue $_.Destination
                netmask = Get-SafeValue $_.Mask
                next_hop = Get-SafeValue $_.NextHop
                interface_index = Get-SafeValue $_.InterfaceIndex
                metric = Get-SafeValue $_.Metric1
                protocol = Get-SafeValue $_.Protocol
                route_type = Get-SafeValue $_.Type
            }
        } | Sort-Object -Property { $_['destination'] })

    $profiles = @()
    $profileRoot = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles'
    if (Test-Path -LiteralPath $profileRoot) {
        $profiles = @(Get-ChildItem -LiteralPath $profileRoot -ErrorAction SilentlyContinue |
            ForEach-Object {
                $props = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                if ($null -eq $props) { return }
                [ordered]@{
                    name = Get-SafeValue $props.ProfileName
                    description = Get-SafeValue $props.Description
                    category = Get-SafeValue $props.Category
                }
            })
    }

    return [ordered]@{
        interfaces = $configs
        macs = @($configs | ForEach-Object { $_['mac_address'] } | Where-Object { $_ -ne 'unknown' } | Select-Object -Unique)
        ipv4_addresses = @($configs | ForEach-Object { $_['ipv4_addresses'] } | Where-Object { $_ })
        default_gateways = @($configs | ForEach-Object { $_['default_gateways'] } | Where-Object { $_ } | Select-Object -Unique)
        dns_servers = @($configs | ForEach-Object { $_['dns_servers'] } | Where-Object { $_ } | Select-Object -Unique)
        routes = $routes
        network_profiles = $profiles
        profile_source_note = 'Network profile names come from the NetworkList registry hive; no network configuration command is invoked.'
        proxy = Get-RegistryValuesByNamePattern -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -NamePattern '(?i)^(ProxyEnable|ProxyServer|ProxyOverride|AutoConfigURL)$'
    }
}

# ---------------------------------------------------------------------------
# Identity, parameters, dry-run gate
# ---------------------------------------------------------------------------

$dealerKnown = ($PSCmdlet.ParameterSetName -eq 'KnownDealer')
$dealerIdValue = 'unknown'
if ($dealerKnown) { $dealerIdValue = $DealerId }
$DealerId = $dealerIdValue
$deviceId = "BF-$DealerId"
$targetHostname = 'unknown'
if ($dealerKnown) { $targetHostname = "bf-$DealerId" }

$currentHostname = Get-SafeValue $env:COMPUTERNAME
if ($currentHostname -eq 'unknown') {
    $currentHostname = Get-SafeValue (Get-ObjectValue (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue) 'Name')
}
$hostName = $currentHostname.ToLower()

$now = Get-Date
$collectedAtUtc = $now.ToUniversalTime().ToString('o')
$collectedAtLocal = $now.ToString('o')

$baseName = "BF-$DealerId-windows-inventory"
$jsonPath = Join-Path $OutputDirectory "$baseName.json"
$markdownPath = Join-Path $OutputDirectory "$baseName.md"

$isElevated = $false
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isElevated = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { $isElevated = $false }

$notes = [System.Collections.Generic.List[string]]::new()
if (-not $dealerKnown) {
    $notes.Add('WARNING: dealer number unknown (-DealerIdUnknown). Output is BF-unknown-windows-inventory.* and must NOT be uploaded to the central inventory until the dealer number is confirmed and the script is re-run with -DealerId.')
}
if (-not $isElevated) {
    $notes.Add('Not running elevated: some CIM sections may be incomplete. Nothing is changed either way.')
}
$notes.Add('Read-only run: no configuration, service, registry or network state is modified and no download is performed.')

if ($Check) {
    $softwarePlan = 'collected'
    if ($NoSoftware) { $softwarePlan = 'skipped (-NoSoftware)' }
    Write-Output "CHECK: $baseName.ps1 read-only dry run"
    Write-Output "  dealer_id      : $dealerIdValue (known: $dealerKnown)"
    Write-Output "  device_id      : $deviceId"
    Write-Output "  hostname       : $hostName"
    Write-Output "  target_hostname: $targetHostname"
    Write-Output "  output_json    : $jsonPath"
    Write-Output "  output_md      : $markdownPath"
    Write-Output "  software_surface: $softwarePlan"
    Write-Output '  writes         : none (dry run)'
    exit 0
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

# ---------------------------------------------------------------------------
# Collection
# ---------------------------------------------------------------------------

$computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
$bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
$operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
$processor = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
$videoController = Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1

$biosSmbiosVersion = Get-SafeValue (Get-ObjectValue $bios 'SMBIOSBIOSVersion')
$biosVersion = $biosSmbiosVersion
if ($biosVersion -eq 'unknown') { $biosVersion = Get-SafeValue (Get-ObjectValue $bios 'Version') }

$windowsRegistry = Get-RegistryValues -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Names @(
    'ProductName', 'EditionID', 'DisplayVersion', 'ReleaseId', 'CurrentBuild', 'UBR', 'InstallationType'
)
# Windows ProductId is a licence identifier and is deliberately not collected.

$hotfixes = @(Get-CimInstance -ClassName Win32_QuickFixEngineering -ErrorAction SilentlyContinue |
    ForEach-Object {
        [ordered]@{
            hotfix_id = Get-SafeValue $_.HotFixID
            description = Get-SafeValue $_.Description
            installed_on = Get-SafeValue $_.InstalledOn
        }
    } | Sort-Object -Property { $_['hotfix_id'] })

$diskData = @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction SilentlyContinue | ForEach-Object {
    [ordered]@{
        name = Get-SafeValue $_.Model
        size_gb = ConvertTo-Gigabytes $_.Size
        interface_type = Get-SafeValue $_.InterfaceType
        media_type = Get-SafeValue $_.MediaType
        serial = Get-SafeValue $_.SerialNumber
        partitions = Get-SafeValue $_.Partitions
    }
})
$volumeData = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue | ForEach-Object {
    [ordered]@{
        drive = Get-SafeValue $_.DeviceID
        label = Get-SafeValue $_.VolumeName
        file_system = Get-SafeValue $_.FileSystem
        size_gb = ConvertTo-Gigabytes $_.Size
        free_gb = ConvertTo-Gigabytes $_.FreeSpace
    }
})
$userProfiles = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
    Where-Object { -not $_.Special -and $_.LocalPath } |
    ForEach-Object {
        [ordered]@{
            path = Get-SafeValue $_.LocalPath
            loaded = [bool]$_.Loaded
            last_use_time = ConvertTo-IsoUtc $_.LastUseTime
        }
    })

$installedSoftware = @()
$serviceSnapshot = $null
$serviceRows = @()
$taskSnapshot = $null
$driverSnapshot = $null
if (-not $NoSoftware) {
    $installedSoftware = @(Get-InstalledSoftware)
    $serviceSnapshot = Get-ServiceSnapshot
    $serviceRows = @($serviceSnapshot['running']) + @($serviceSnapshot['relevant_to_migration'])
    $taskSnapshot = Get-ScheduledTaskSnapshot
    $driverSnapshot = Get-DriverSnapshot
}

$megRoots = @(Get-ProgramFilesRoots)

$inventory = [ordered]@{
    schema_version = 1
    report_type = 'windows-pre-migration-inventory'
    device_id = $deviceId
    hostname = $hostName
    current_hostname = $currentHostname
    target_hostname = $targetHostname
    dealer_id = $dealerIdValue
    dealer_id_known = [bool]$dealerKnown
    collected_at = $collectedAtLocal
    collected_at_utc = $collectedAtUtc
    read_only = $true
    collection_scope = [ordered]@{
        read_only = $true
        elevated = [bool]$isElevated
        software_surface_included = (-not $NoSoftware)
        executed_external_tools = @()
        excluded = @(
            'credentials', 'passwords', 'private keys', 'tokens', 'file contents',
            'browser profiles', 'event logs', 'DPAPI blobs', 'Windows ProductId',
            'VPN tunnel/profile file contents', 'RustDesk id_ed25519 private key'
        )
    }
    notes = @($notes)
    manufacturer = Get-SafeValue (Get-ObjectValue $computerSystem 'Manufacturer')
    model = Get-SafeValue (Get-ObjectValue $computerSystem 'Model')
    serial = Get-SafeValue (Get-ObjectValue $bios 'SerialNumber')
    bios = [ordered]@{
        vendor = Get-SafeValue (Get-ObjectValue $bios 'Manufacturer')
        version = $biosVersion
        smbios_version = $biosSmbiosVersion
        date = Get-SafeValue (Get-ObjectValue $bios 'ReleaseDate')
    }
    cpu = [ordered]@{
        model = Get-SafeValue (Get-ObjectValue $processor 'Name')
        cores = Get-SafeValue (Get-ObjectValue $processor 'NumberOfCores')
        logical_processors = Get-SafeValue (Get-ObjectValue $processor 'NumberOfLogicalProcessors')
        arch = Get-SafeValue (Get-ObjectValue $operatingSystem 'OSArchitecture')
        address_width = Get-SafeValue (Get-ObjectValue $processor 'AddressWidth')
    }
    memory_mb = ConvertTo-Megabytes (Get-ObjectValue $computerSystem 'TotalPhysicalMemory')
    disks = $diskData
    volumes = $volumeData
    gpu = [ordered]@{
        model = Get-SafeValue (Get-ObjectValue $videoController 'Name')
        driver_version = Get-SafeValue (Get-ObjectValue $videoController 'DriverVersion')
        video_processor = Get-SafeValue (Get-ObjectValue $videoController 'VideoProcessor')
        adapter_ram_mb = ConvertTo-Megabytes (Get-ObjectValue $videoController 'AdapterRAM')
    }
    os = [ordered]@{
        distro = Get-SafeValue (Get-ObjectValue $operatingSystem 'Caption')
        version = Get-SafeValue (Get-ObjectValue $operatingSystem 'Version')
        build = Get-SafeValue (Get-ObjectValue $operatingSystem 'BuildNumber')
    }
    windows = [ordered]@{
        product_name = $windowsRegistry['ProductName']
        edition_id = $windowsRegistry['EditionID']
        display_version = $windowsRegistry['DisplayVersion']
        release_id = $windowsRegistry['ReleaseId']
        current_build = $windowsRegistry['CurrentBuild']
        ubr = $windowsRegistry['UBR']
        installation_type = $windowsRegistry['InstallationType']
        caption = Get-SafeValue (Get-ObjectValue $operatingSystem 'Caption')
        version = Get-SafeValue (Get-ObjectValue $operatingSystem 'Version')
        build = Get-SafeValue (Get-ObjectValue $operatingSystem 'BuildNumber')
        architecture = Get-SafeValue (Get-ObjectValue $operatingSystem 'OSArchitecture')
        install_date = ConvertTo-IsoUtc (Get-ObjectValue $operatingSystem 'InstallDate')
        last_boot = ConvertTo-IsoUtc (Get-ObjectValue $operatingSystem 'LastBootUpTime')
        product_id_collected = $false
        hotfixes = $hotfixes
    }
    network = Get-NetworkSnapshot
    serial_ports = Get-ComPortSnapshot
    usb = Get-UsbSnapshot
    drivers = $driverSnapshot
    installed_software = $installedSoftware
    services = $serviceSnapshot
    scheduled_tasks = $taskSnapshot
    docker = Get-DockerSnapshot
    vpn = Get-VpnSnapshot -Software $installedSoftware -Services $serviceRows
    remote_access = Get-RemoteAccessSnapshot -Services $serviceRows
    meg = Get-MegSnapshot -Software $installedSoftware -Services $serviceRows -Roots $megRoots
    user_profiles = $userProfiles
}

$inventory | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonPath -Encoding utf8

# ---------------------------------------------------------------------------
# Markdown report
# ---------------------------------------------------------------------------

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("# Windows Ön Geçiş Envanteri — $deviceId")
$lines.Add('')
$lines.Add("- Toplama zamanı (UTC): $collectedAtUtc")
$lines.Add("- Mevcut hostname: $currentHostname")
$lines.Add("- Hedef hostname (geçiş sonrası): $targetHostname")
$lines.Add("- Bayi numarası biliniyor mu: $dealerKnown")
$lines.Add("- Kapsam: yalnız okuma; kimlik bilgisi, parola, private key, dosya içeriği ve olay kaydı toplanmaz.")
$lines.Add('')
if ($notes.Count -gt 0) {
    $lines.Add('## Uyarılar')
    foreach ($note in $notes) { $lines.Add("- $note") }
    $lines.Add('')
}
$lines.Add('## Kimlik ve donanım')
$lines.Add('')
$lines.Add('| Alan | Değer |')
$lines.Add('|---|---|')
foreach ($item in @(
    @{ Name = 'Device ID'; Value = $inventory.device_id },
    @{ Name = 'Mevcut hostname'; Value = $inventory.current_hostname },
    @{ Name = 'Hedef hostname'; Value = $inventory.target_hostname },
    @{ Name = 'Üretici'; Value = $inventory.manufacturer },
    @{ Name = 'Model'; Value = $inventory.model },
    @{ Name = 'Seri no'; Value = $inventory.serial },
    @{ Name = 'BIOS'; Value = "$($inventory.bios.version)" },
    @{ Name = 'CPU'; Value = "$($inventory.cpu.model)" },
    @{ Name = 'Çekirdek'; Value = "$($inventory.cpu.cores)/$($inventory.cpu.logical_processors)" },
    @{ Name = 'Mimari'; Value = $inventory.cpu.arch },
    @{ Name = 'RAM (MB)'; Value = $inventory.memory_mb },
    @{ Name = 'GPU'; Value = $inventory.gpu.model }
)) { $lines.Add("| $($item['Name']) | $(ConvertTo-MarkdownCell $item['Value']) |") }
$lines.Add('')
$lines.Add('## Windows sürümü')
$lines.Add('')
$lines.Add('| Alan | Değer |')
$lines.Add('|---|---|')
foreach ($item in @(
    @{ Name = 'Ürün'; Value = $inventory.windows.product_name },
    @{ Name = 'Sürüm (DisplayVersion)'; Value = $inventory.windows.display_version },
    @{ Name = 'ReleaseId'; Value = $inventory.windows.release_id },
    @{ Name = 'Build'; Value = "$($inventory.windows.current_build).$($inventory.windows.ubr)" },
    @{ Name = 'Kurulum tipi'; Value = $inventory.windows.installation_type },
    @{ Name = 'Kurulum tarihi'; Value = $inventory.windows.install_date },
    @{ Name = 'Son boot'; Value = $inventory.windows.last_boot },
    @{ Name = 'Hotfix sayısı'; Value = $inventory.windows.hotfixes.Count }
)) { $lines.Add("| $($item['Name']) | $(ConvertTo-MarkdownCell $item['Value']) |") }
$lines.Add('')
$lines.Add('## Diskler ve birimler')
$lines.Add('')
foreach ($disk in $inventory.disks) {
    $lines.Add("- $($disk['name']): $($disk['size_gb']) GB ($($disk['interface_type']), $($disk['media_type'])); seri: $($disk['serial'])")
}
foreach ($volume in $inventory.volumes) {
    $lines.Add("- Birim $($volume['drive']) ($($volume['label'])): $($volume['free_gb'])/$($volume['size_gb']) GB boş, $($volume['file_system'])")
}
$lines.Add('')
$lines.Add('## Ağ')
$lines.Add('')
$lines.Add('| Bağdaştırıcı | MAC | DHCP | IPv4 | Gateway | DNS |')
$lines.Add('|---|---|---|---|---|---|')
foreach ($adapter in $inventory.network.interfaces) {
    $lines.Add("| $(ConvertTo-MarkdownCell $adapter['description']) | $($adapter['mac_address']) | $($adapter['dhcp_enabled']) | $($adapter['ipv4_addresses'] -join ', ') | $($adapter['default_gateways'] -join ', ') | $($adapter['dns_servers'] -join ', ') |")
}
$lines.Add('')
$lines.Add("- Varsayılan gateway'ler: $($inventory.network.default_gateways -join ', ')")
$lines.Add("- DNS sunucuları: $($inventory.network.dns_servers -join ', ')")
$lines.Add('')
$lines.Add('### Yönlendirme tablosu (IPv4)')
$lines.Add('')
$lines.Add('| Hedef | Mask | Next hop | Metric |')
$lines.Add('|---|---|---|---|')
foreach ($route in $inventory.network.routes) {
    $lines.Add("| $($route['destination']) | $($route['netmask']) | $($route['next_hop']) | $($route['metric']) |")
}
$lines.Add('')
$lines.Add('### Ağ profilleri, proxy')
$lines.Add('')
foreach ($profile in $inventory.network.network_profiles) {
    $lines.Add("- Profil: $($profile['name']) ($($profile['description']))")
}
foreach ($entry in $inventory.network.proxy.GetEnumerator()) {
    $lines.Add("- Proxy $($entry.Key): $($entry.Value)")
}
$lines.Add('')
$lines.Add('## Seri / COM portları')
$lines.Add('')
foreach ($port in $inventory.serial_ports.cim_serial_ports) {
    $lines.Add("- $($port['device_id']): $($port['name']) ($($port['description']))")
}
foreach ($port in $inventory.serial_ports.pnp_com_devices) {
    $lines.Add("- PnP: $($port['name']) — $($port['device_id']) [$($port['status'])]")
}
foreach ($entry in $inventory.serial_ports.registry_devicemap.GetEnumerator()) {
    $lines.Add("- SERIALCOMM $($entry.Key) = $($entry.Value)")
}
$lines.Add('')
$lines.Add('## USB ve donanım kimlikleri')
$lines.Add('')
foreach ($device in $inventory.usb.devices) {
    $lines.Add("- $($device['name']) — $($device['hardware_id']) [$($device['status'])]")
}
$lines.Add('')
$lines.Add("- USB denetleyici sayısı: $($inventory.usb.controllers.Count)")
$lines.Add('')
$lines.Add('## Docker')
$lines.Add('')
$lines.Add("- Kurulu: $($inventory.docker.present)")
$lines.Add("- CLI: $($inventory.docker.docker_cli_path) (sürüm: $($inventory.docker.docker_cli_file_version))")
$lines.Add("- Docker Desktop: $($inventory.docker.desktop_app_path)")
if ($null -ne $inventory.docker.service) {
    $lines.Add("- Servis: $($inventory.docker.service['name']) [$($inventory.docker.service['state'])]")
}
$lines.Add("- WSL dağıtımları: $($inventory.docker.wsl_distributions -join ', ')")
$lines.Add('')
$lines.Add('## VPN istemcileri')
$lines.Add('')
$wireguardNames = @($inventory.vpn.wireguard.registry_tunnels) + @(Get-NamesOf $inventory.vpn.wireguard.tunnel_config_files)
$openVpnNames = @(Get-NamesOf $inventory.vpn.openvpn.profile_files)
$lines.Add("- WireGuard kurulu: $($inventory.vpn.wireguard.present); tüneller: $($wireguardNames -join ', ')")
$lines.Add("- OpenVPN kurulu: $($inventory.vpn.openvpn.present); profiller: $($openVpnNames -join ', ')")
foreach ($app in $inventory.vpn.installed_vpn_software) {
    $lines.Add("- VPN yazılımı: $($app['name']) $($app['version'])")
}
foreach ($svc in $inventory.vpn.vpn_services) {
    $lines.Add("- VPN servisi: $($svc['name']) [$($svc['state'])]")
}
$lines.Add('')
$lines.Add('## Uzak erişim kimlikleri')
$lines.Add('')
$lines.Add("- RustDesk ID: $($inventory.remote_access.rustdesk_id)")
$lines.Add("- AnyDesk ID: $($inventory.remote_access.anydesk_id)")
foreach ($svc in $inventory.remote_access.remote_access_services) {
    $lines.Add("- Uzak erişim servisi: $($svc['name']) [$($svc['state'])]")
}
$lines.Add('')
$lines.Add('## MEG (uygulama / servis / config yolları)')
$lines.Add('')
foreach ($app in $inventory.meg.software) {
    $lines.Add("- Uygulama: $($app['name']) $($app['version']) — $($app['install_location'])")
}
foreach ($svc in $inventory.meg.services) {
    $lines.Add("- Servis: $($svc['name']) [$($svc['state'])]")
}
foreach ($dir in $inventory.meg.config_directories) {
    $lines.Add("- Dizin: $($dir['path']) (son yazma: $($dir['last_write_utc']))")
}
foreach ($key in $inventory.meg.registry_keys) {
    $lines.Add("- Registry anahtarı: $key")
}
$lines.Add('')
if ($NoSoftware) {
    $lines.Add('## Yazılım yüzeyi')
    $lines.Add('')
    $lines.Add('Yazılım envanteri (yüklü yazılım, servisler, zamanlanmış görevler, sürücüler) -NoSoftware nedeniyle alınmadı; ilgili JSON alanları boş bırakıldı.')
} else {
    $lines.Add('## Yüklü yazılım')
    $lines.Add('')
    foreach ($software in $inventory.installed_software) {
        $lines.Add("- $($software['name']) — $($software['version']) ($($software['publisher']))")
    }
    $lines.Add('')
    $lines.Add('## Servisler (çalışan, göçle ilgili, auto-start ama durmuş)')
    $lines.Add('')
    foreach ($svc in $inventory.services.running) {
        $lines.Add("- [çalışıyor] $($svc['name']) — $($svc['display_name'])")
    }
    foreach ($svc in $inventory.services.auto_start_but_stopped) {
        $lines.Add("- [durmuş, auto] $($svc['name']) — $($svc['display_name'])")
    }
    $lines.Add('')
    $lines.Add('## Zamanlanmış görevler (Microsoft dışı)')
    $lines.Add('')
    if ($inventory.scheduled_tasks.available) {
        foreach ($task in $inventory.scheduled_tasks.items) {
            $lines.Add("- $($task['task_path'])$($task['task_name']) [$($task['state'])]")
        }
    } else {
        $lines.Add($inventory.scheduled_tasks.note)
    }
    $lines.Add('')
    $lines.Add("## Sürücüler ($($inventory.drivers.total) kayıt)")
    $lines.Add('')
    foreach ($driver in $inventory.drivers.items) {
        $lines.Add("- $($driver['device_name']) — $($driver['driver_version']) ($($driver['driver_provider']))")
    }
}
$lines.Add('')
$lines.Add('## Kullanıcı profilleri')
$lines.Add('')
foreach ($profile in $inventory.user_profiles) {
    $lines.Add("- $($profile['path']) (son kullanım: $($profile['last_use_time']))")
}
$lines.Add('')
$lines.Add('---')
$lines.Add('')
$lines.Add('Bu rapor salt-okunur bir taramadır; hiçbir ayar, servis, ağ veya registry durumu değiştirilmedi. Veri aktarımı için BF-WindowsDataExport.ps1 kullanılır.')
$lines | Set-Content -LiteralPath $markdownPath -Encoding utf8

Write-Output "Wrote $jsonPath and $markdownPath"
