<#
.SYNOPSIS
  Read-only Windows pre-migration data-export manifest for one Blueforce dealer.
.DESCRIPTION
  Produces metadata only: approved user folders, removable-drive roots, mapped
  network shares, printers and MEG data directories are listed for an operator
  to review before any manual copy happens.

  READ-ONLY CONTRACT (asserted by tests/check-migration-static.sh):
    * No Set-*, New-*, Remove-* cmdlets, no service control, no network
      configuration command, no registry write, no download.
    * Nothing is copied, moved, compressed or encrypted.
    * No file contents, credentials, browser profiles, password stores,
      private keys or application databases are read.
    * Directory metadata (path, size, timestamps) only.
    * The only writes are the requested JSON and Markdown reports under
      -OutputDirectory; with -Check nothing is written at all.

  Output contract: BF-<no>-windows-inventory-export.json and
  BF-<no>-windows-inventory-export.md, named from the 8-digit dealer number -
  not from the hostname of the machine being inventoried.
.PARAMETER DealerId
  8-digit Blueforce dealer number (^[0-9]{8}$). Device ID becomes BF-<no>.
.PARAMETER DealerIdUnknown
  Explicit opt-in for a device whose dealer number is not known yet. The report
  is written as BF-unknown-windows-inventory-export.* and carries a prominent
  warning: it must not be attached to a migration record until the dealer
  number is confirmed and the script is re-run with -DealerId.
.PARAMETER OutputDirectory
  Directory that receives the JSON and Markdown export manifest.
.PARAMETER NoSoftware
  Skip the installed-software review list.
.PARAMETER Check
  Dry run: validate parameters, print the export plan and the resolved output
  paths, write nothing, exit 0.
.EXAMPLE
  .\BF-WindowsDataExport.ps1 -DealerId 12010193 -OutputDirectory C:\Blueforce\migration
.EXAMPLE
  .\BF-WindowsDataExport.ps1 -DealerIdUnknown -OutputDirectory C:\Blueforce\migration -Check
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

function ConvertTo-IsoUtc {
    param([object]$Value)
    if ($null -eq $Value) { return 'unknown' }
    try { return ([datetime]$Value).ToUniversalTime().ToString('o') } catch { return 'unknown' }
}

function Get-ObjectValue {
    param([object]$InputObject, [string]$Name)
    if ($null -eq $InputObject) { return $null }
    $prop = $InputObject.PSObject.Properties | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Get-FolderMetadata {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $null }
    $item = Get-Item -LiteralPath $Path -Force
    [ordered]@{
        path = $item.FullName
        last_write_utc = $item.LastWriteTimeUtc.ToString('o')
        review_required = $true
        export_action = 'manual-copy-after-owner-approval'
    }
}

function Get-ProgramFilesRoots {
    $roots = @()
    if ($env:ProgramFiles) { $roots += $env:ProgramFiles }
    if (${env:ProgramFiles(x86)}) { $roots += ${env:ProgramFiles(x86)} }
    if ($env:ProgramData) { $roots += $env:ProgramData }
    $roots += 'C:\'
    return @($roots | Select-Object -Unique)
}

# Directory metadata only (path + mtime); contents are never enumerated.
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

# ---------------------------------------------------------------------------
# Identity, parameters, dry-run gate
# ---------------------------------------------------------------------------

$dealerKnown = ($PSCmdlet.ParameterSetName -eq 'KnownDealer')
$dealerIdValue = 'unknown'
if ($dealerKnown) { $dealerIdValue = $DealerId }
$DealerId = $dealerIdValue
$deviceId = "BF-$DealerId"

$currentHostname = Get-SafeValue $env:COMPUTERNAME
$targetHostname = 'unknown'
if ($dealerKnown) { $targetHostname = "bf-$DealerId" }

$now = Get-Date
$collectedAtUtc = $now.ToUniversalTime().ToString('o')
$collectedAtLocal = $now.ToString('o')

$baseName = "BF-$DealerId-windows-inventory-export"
$jsonPath = Join-Path $OutputDirectory "$baseName.json"
$markdownPath = Join-Path $OutputDirectory "$baseName.md"

$notes = [System.Collections.Generic.List[string]]::new()
if (-not $dealerKnown) {
    $notes.Add('WARNING: dealer number unknown (-DealerIdUnknown). Output is BF-unknown-windows-inventory-export.* and must NOT be attached to a migration record until the dealer number is confirmed and the script is re-run with -DealerId.')
}
$notes.Add('Read-only run: this manifest lists metadata for review; it copies, moves and deletes nothing.')

if ($Check) {
    $softwarePlan = 'collected'
    if ($NoSoftware) { $softwarePlan = 'skipped (-NoSoftware)' }
    Write-Output "CHECK: $baseName.ps1 read-only dry run"
    Write-Output "  dealer_id         : $dealerIdValue (known: $dealerKnown)"
    Write-Output "  device_id         : $deviceId"
    Write-Output "  hostname          : $currentHostname"
    Write-Output "  target_hostname   : $targetHostname"
    Write-Output "  output_json       : $jsonPath"
    Write-Output "  output_md         : $markdownPath"
    Write-Output "  software_review   : $softwarePlan"
    Write-Output '  writes            : none (dry run)'
    exit 0
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

# ---------------------------------------------------------------------------
# Collection (metadata only)
# ---------------------------------------------------------------------------

$candidateFolderNames = @('Desktop', 'Documents', 'Downloads', 'Pictures', 'Videos', 'Music', 'Favorites')
$skippedFolderNames = @('AppData', '.ssh', '.gnupg', '.aws', '.azure', '.config', 'Cookies', 'Searches')

$userFolders = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
    Where-Object { -not $_.Special -and $_.LocalPath } |
    ForEach-Object {
        $root = $_.LocalPath
        @($candidateFolderNames | ForEach-Object { Get-FolderMetadata (Join-Path $root $_) } | Where-Object { $null -ne $_ })
    })

$removableRoots = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=2' -ErrorAction SilentlyContinue | ForEach-Object {
    [ordered]@{
        path = "$($_.DeviceID)\"
        label = Get-SafeValue $_.VolumeName
        file_system = Get-SafeValue $_.FileSystem
        size_gb = ConvertTo-Gigabytes $_.Size
        free_gb = ConvertTo-Gigabytes $_.FreeSpace
        review_required = $true
        export_action = 'manual-copy-after-owner-approval'
    }
})

# Mapped network shares: connection metadata only; nothing is read from them.
$mappedDrives = @(Get-CimInstance -ClassName Win32_NetworkConnection -ErrorAction SilentlyContinue | ForEach-Object {
    [ordered]@{
        local_name = Get-SafeValue $_.LocalName
        remote_name = Get-SafeValue $_.RemoteName
        connection_type = Get-SafeValue $_.ConnectionType
        status = Get-SafeValue $_.Status
        review_required = $true
        export_action = 'manual-copy-after-owner-approval'
    }
})

# Printers matter for field terminals (label/receipt printers); configuration
# is recorded, no print job or driver change is issued.
$printers = @(Get-CimInstance -ClassName Win32_Printer -ErrorAction SilentlyContinue | ForEach-Object {
    [ordered]@{
        name = Get-SafeValue $_.Name
        driver_name = Get-SafeValue $_.DriverName
        port_name = Get-SafeValue $_.PortName
        is_default = [bool]$_.Default
        is_network = [bool]$_.Network
        is_shared = [bool]$_.Shared
        share_name = Get-SafeValue $_.ShareName
    }
})

# MEG data directories: path metadata only, no enumeration of contents.
$megDataDirectories = @()
foreach ($root in (Get-ProgramFilesRoots)) {
    $megDataDirectories += @(Get-DirectoryReport -Root $root -Filter '*MEG*')
}

$installedSoftwareReview = @()
if (-not $NoSoftware) {
    $installedSoftwareReview = @(Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName } |
        ForEach-Object {
            [ordered]@{
                name = Get-SafeValue $_.DisplayName
                version = Get-SafeValue $_.DisplayVersion
                install_location = Get-SafeValue $_.InstallLocation
            }
        } | Sort-Object -Property { $_['name'] })
}

$report = [ordered]@{
    schema_version = 1
    report_type = 'windows-pre-migration-data-export-manifest'
    device_id = $deviceId
    hostname = $currentHostname.ToLower()
    current_hostname = $currentHostname
    target_hostname = $targetHostname
    dealer_id = $dealerIdValue
    dealer_id_known = [bool]$dealerKnown
    collected_at = $collectedAtLocal
    collected_at_utc = $collectedAtUtc
    read_only = $true
    copies_performed = 0
    executed_external_tools = @()
    notes = @($notes)
    excluded_data = @(
        'file contents', 'credentials', 'passwords', 'browser profiles', 'private keys',
        'application databases', 'event logs', 'DPAPI blobs',
        'AppData', '.ssh', '.gnupg', '.aws', '.azure', '.config',
        'Cookies', 'Searches', 'Windows credential vault'
    )
    candidate_folder_names = $candidateFolderNames
    skipped_folder_names = $skippedFolderNames
    candidate_folders = @($userFolders)
    removable_media_roots = $removableRoots
    mapped_network_drives = $mappedDrives
    printers = $printers
    meg_data_directories = $megDataDirectories
    installed_software_review = $installedSoftwareReview
}

$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding utf8

# ---------------------------------------------------------------------------
# Markdown report
# ---------------------------------------------------------------------------

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("# Windows Veri Aktarım İnceleme Kaydı — $deviceId")
$lines.Add('')
$lines.Add("- Toplama zamanı (UTC): $collectedAtUtc")
$lines.Add("- Mevcut hostname: $currentHostname")
$lines.Add("- Hedef hostname (geçiş sonrası): $targetHostname")
$lines.Add("- Bayi numarası biliniyor mu: $dealerKnown")
$lines.Add('- Bu rapor yalnız metadata içerir; hiçbir dosya kopyalanmaz, taşınmaz veya silinmez.')
$lines.Add('- Aktarım, iş sahibi onayı ve hedef medya doğrulaması sonrasında elle yapılmalıdır.')
$lines.Add('- Hariç tutulanlar: AppData, tarayıcı profilleri, kimlik bilgileri, private key ve uygulama veritabanları.')
$lines.Add('')
if ($notes.Count -gt 0) {
    $lines.Add('## Uyarılar')
    foreach ($note in $notes) { $lines.Add("- $note") }
    $lines.Add('')
}
$lines.Add('## İncelenecek klasörler')
$lines.Add('')
foreach ($folder in $report.candidate_folders) {
    $lines.Add("- $($folder['path']) — son değişiklik: $($folder['last_write_utc'])")
}
$lines.Add('')
$lines.Add('## Çıkarılabilir medya kökleri')
$lines.Add('')
foreach ($drive in $report.removable_media_roots) {
    $lines.Add("- $($drive['path']) ($($drive['label'])): $($drive['free_gb'])/$($drive['size_gb']) GB boş")
}
$lines.Add('')
$lines.Add('## Eşlenmiş ağ sürücüleri')
$lines.Add('')
foreach ($drive in $report.mapped_network_drives) {
    $lines.Add("- $($drive['local_name']) → $($drive['remote_name']) [$($drive['status'])]")
}
$lines.Add('')
$lines.Add('## Yazıcılar')
$lines.Add('')
foreach ($printer in $report.printers) {
    $lines.Add("- $($printer['name']) — sürücü: $($printer['driver_name']), port: $($printer['port_name'])")
}
$lines.Add('')
$lines.Add('## MEG veri dizinleri (metadata)')
$lines.Add('')
foreach ($dir in $report.meg_data_directories) {
    $lines.Add("- $($dir['path']) (son yazma: $($dir['last_write_utc']))")
}
$lines.Add('')
if ($NoSoftware) {
    $lines.Add('Yazılım incelemesi -NoSoftware nedeniyle alınmadı.')
} else {
    $lines.Add('## Yazılım incelemesi')
    $lines.Add('')
    foreach ($software in $report.installed_software_review) {
        $lines.Add("- $($software['name']) — $($software['version'])")
    }
}
$lines.Add('')
$lines.Add('---')
$lines.Add('')
$lines.Add('Bu manifest salt-okunur bir inceleme kaydıdır. Donanım/ağ/yazılım tarafı için BF-WindowsPreMigrationInventory.ps1 kullanılır.')
$lines | Set-Content -LiteralPath $markdownPath -Encoding utf8

Write-Output "Wrote $jsonPath and $markdownPath"
