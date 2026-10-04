#Requires -Version 7.0
<#
.SYNOPSIS
    Alpheus - disk reclamation and performance audit for Windows 10/11 (PowerShell 7).

.DESCRIPTION
    Named for the river Heracles diverted through the Augean stables: it washes out
    the accumulated muck and leaves the livestock alone.

    DEFAULT MODE IS READ-ONLY. With no switches the script only measures and reports:
      - free space per fixed volume, disk health, TRIM
      - size of every cleanup target, tiered SAFE / OPT-IN / PROTECTED
      - largest files in the user profile and Downloads
      - performance signals: CPU microcode (13th/14th-gen instability), unexpected
        shutdowns / WHEA / bugchecks, pending reboot, uptime, startup items,
        third-party auto services, top RAM consumers, per-process GPU memory (MiB)

    Nothing is deleted unless -Apply is passed. -WhatIf and -Confirm are honoured.

    PROTECTED (measured, never touched by any switch):
      Downloads, the Ollama model store, Hugging Face / torch caches, WSL/Docker
      virtual disks, shadow copies, Windows.old - plus any folders you list in
      alpheus.config.json (see alpheus.config.example.json).

.PARAMETER Apply
    Perform cleanup. Without -Include, runs the SAFE set only.

.PARAMETER Include
    Categories to clean when -Apply is set.
    SAFE set : Temp, WER, DeliveryOpt, WUCache, NvidiaInstallers
    OPT-IN   : CrashDumps, DevCaches, BrowserCache, RecycleBin, ComponentStore, Hibernation
    Meta     : Safe, All

.PARAMETER TempAgeDays
    Only delete temp files older than this many days (default 2) so running jobs keep their scratch.

.PARAMETER ResetBase
    With ComponentStore, also pass /ResetBase (frees more; installed updates can no longer be uninstalled).

.PARAMETER ConfigPath
    Optional JSON file adding your own PROTECTED folders. Default: the first alpheus.config.json found
    next to this script, then in %LOCALAPPDATA%\Alpheus (where Alpheus.exe users keep it). No file =
    built-in protections only. An unreadable file, or a -ConfigPath that does not exist, stops the run.

.PARAMETER Deep
    Also size every top-level folder on each fixed volume and run DISM /AnalyzeComponentStore. Slow.

.EXAMPLE
    .\Invoke-Alpheus.ps1                                   # audit only
    .\Invoke-Alpheus.ps1 -Deep                             # audit + whole-drive breakdown
    .\Invoke-Alpheus.ps1 -Apply -WhatIf                    # show what the SAFE set would do
    .\Invoke-Alpheus.ps1 -Apply                            # clean the SAFE set
    .\Invoke-Alpheus.ps1 -Apply -Include DevCaches,ComponentStore
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [switch]$Apply,
    [ValidateSet('Safe', 'All', 'Temp', 'WER', 'DeliveryOpt', 'WUCache', 'NvidiaInstallers',
        'CrashDumps', 'DevCaches', 'BrowserCache', 'RecycleBin', 'ComponentStore', 'Hibernation')]
    [string[]]$Include = @('Safe'),
    [ValidateRange(0, 365)]
    [int]$TempAgeDays = 2,
    [switch]$ResetBase,
    [switch]$Deep,
    # Skip the extra crash-dump prompt (the GUI asks its own question first).
    [switch]$Force,
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'   # no progress records: faster, and nothing for a redirected host to serialise
if ($PSStyle) { $PSStyle.OutputRendering = 'PlainText' }   # no ANSI in tables when piped to the GUI or a file

# ---------------------------------------------------------------- setup
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$Stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$OutDir = Join-Path $env:LOCALAPPDATA 'Alpheus'
$null   = New-Item -ItemType Directory -Path $OutDir -Force -WhatIf:$false
$LogPath  = Join-Path $OutDir "alpheus-$Stamp.log"
$JsonPath = Join-Path $OutDir "alpheus-$Stamp.json"
Start-Transcript -Path $LogPath -Force -WhatIf:$false | Out-Null

$SafeSet = 'Temp', 'WER', 'DeliveryOpt', 'WUCache', 'NvidiaInstallers'
$OptSet  = 'CrashDumps', 'DevCaches', 'BrowserCache', 'RecycleBin', 'ComponentStore', 'Hibernation'
$Selected = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($i in $Include) {
    switch ($i) {
        'Safe'  { $SafeSet | ForEach-Object { [void]$Selected.Add($_) } }
        'All'   { ($SafeSet + $OptSet) | ForEach-Object { [void]$Selected.Add($_) } }
        default { [void]$Selected.Add($i) }
    }
}

function Write-Section([string]$Title) {
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkGray
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor DarkGray
}

function Format-Size([Nullable[long]]$Bytes) {
    if ($null -eq $Bytes) { return '-' }
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

function New-EnumOptions {
    $o = [System.IO.EnumerationOptions]::new()
    $o.RecurseSubdirectories = $true
    $o.IgnoreInaccessible    = $true
    $o.AttributesToSkip      = [System.IO.FileAttributes]::ReparsePoint   # include hidden/system, never follow junctions
    return $o
}

function Get-PathSize([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue)) { return $null }   # unelevated: system paths deny
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    if ($item -is [System.IO.FileInfo]) { return [long]$item.Length }
    $sum = 0L
    try {
        foreach ($f in [System.IO.DirectoryInfo]::new($item.FullName).EnumerateFiles('*', (New-EnumOptions))) {
            $sum += $f.Length
        }
    } catch { }
    return $sum
}

function Clear-PathContents([string]$Path, [int]$OlderThanDays = 0) {
    # Deletes files (optionally age-gated) under $Path, then prunes empty non-reparse subdirs.
    # Never removes $Path itself. Locked files are skipped silently.
    # Anything under a PROTECTED path is skipped even when it sits inside a cleanup target.
    if (-not (Test-Path -LiteralPath $Path)) { return 0L }
    if (Test-UnderProtected $Path) { Write-Host "    skipped $Path - it is PROTECTED" -ForegroundColor Yellow; return 0L }
    $cut = (Get-Date).AddDays(-$OlderThanDays)
    $freed = 0L; $skipped = 0
    foreach ($f in [System.IO.DirectoryInfo]::new($Path).EnumerateFiles('*', (New-EnumOptions))) {
        if ($f.LastWriteTime -gt $cut) { continue }
        if (Test-UnderProtected $f.FullName) { continue }
        try {
            $len = $f.Length
            if ($f.IsReadOnly) { $f.IsReadOnly = $false }
            $f.Delete(); $freed += $len
        } catch { $skipped++ }
    }
    Get-ChildItem -LiteralPath $Path -Directory -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and -not (Test-UnderProtected $_.FullName) } |
        Sort-Object { $_.FullName.Length } -Descending |
        ForEach-Object {
            if (-not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    if ($skipped) { Write-Host "    skipped $skipped locked/in-use file(s) in $Path" -ForegroundColor DarkYellow }
    return $freed
}

function Test-PendingReboot {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($k in $keys) { if (Test-Path $k) { return $true } }
    $pfro = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    return [bool]$pfro
}

# ---------------------------------------------------------------- known locations
$L  = $env:LOCALAPPDATA
$U  = $env:USERPROFILE
$PD = $env:ProgramData
$OllamaModels = if ($env:OLLAMA_MODELS) { $env:OLLAMA_MODELS } else { Join-Path $U '.ollama\models' }

# Your own PROTECTED folders (models, projects, vaults). Fail closed: if the file exists but cannot be
# read, stop rather than run with protections silently missing.
$UserProtected = @()
if ($PSBoundParameters.ContainsKey('ConfigPath')) {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        Write-Host " -ConfigPath $ConfigPath does not exist. Refusing to run without the protections you asked for." -ForegroundColor Red
        Stop-Transcript -ErrorAction SilentlyContinue -WhatIf:$false | Out-Null
        exit 2
    }
} else {
    $ConfigPath = @((Join-Path $PSScriptRoot 'alpheus.config.json'), (Join-Path $env:LOCALAPPDATA 'Alpheus\alpheus.config.json')) |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}
if ($ConfigPath) {
    Write-Host " Config: $ConfigPath"
    try {
        $cfg = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        foreach ($p in @($cfg['Protected'])) {
            if ($p -isnot [hashtable] -or -not $p['Name'] -or -not $p['Paths']) { throw "each Protected entry needs Name and Paths" }
            $paths = @($p['Paths'] | ForEach-Object {
                $raw = [string]$_
                # Checked before expansion: the Win32 expander silently truncates at an embedded NUL.
                if ([string]::IsNullOrWhiteSpace($raw) -or $raw.Contains([char]0)) { throw "'$($p['Name'])' has an empty or invalid path" }
                $x = [Environment]::ExpandEnvironmentVariables($raw)
                # Relative paths would resolve against whatever folder the engine runs from.
                if (-not [IO.Path]::IsPathFullyQualified($x)) { throw "'$($p['Name'])': '$raw' is not a full path (use C:\... or %VAR%\...)" }
                $x
            })
            $UserProtected += [pscustomobject]@{
                Name      = [string]$p['Name']
                Paths     = $paths
                Note      = if ($p['Note']) { [string]$p['Note'] } else { 'yours; prune by hand' }
                Breakdown = [bool]$p['Breakdown']
            }
        }
    } catch {
        Write-Host " Config $ConfigPath is unreadable: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ' Refusing to run with an unknown set of protected folders. Fix or remove the file.' -ForegroundColor Red
        Stop-Transcript -ErrorAction SilentlyContinue -WhatIf:$false | Out-Null
        exit 2
    }
}

$BrowserCacheDirs = foreach ($root in @("$L\Google\Chrome\User Data", "$L\Microsoft\Edge\User Data", "$L\BraveSoftware\Brave-Browser\User Data")) {
    if (Test-Path -LiteralPath $root) {
        Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } |
            ForEach-Object { foreach ($c in 'Cache', 'Code Cache', 'GPUCache') { Join-Path $_.FullName $c } }
    }
}

# Tier: SAFE = in default -Apply set; OPT-IN = only by name; PROTECTED = never touched; INFO = context only
$Targets = @(
    @{ Cat = 'Temp';             Tier = 'SAFE';      Paths = @($env:TEMP, "$env:SystemRoot\Temp");   Note = "files older than $TempAgeDays d" }
    @{ Cat = 'WER';              Tier = 'SAFE';      Paths = @("$PD\Microsoft\Windows\WER\ReportArchive", "$PD\Microsoft\Windows\WER\ReportQueue", "$L\Microsoft\Windows\WER"); Note = 'error-report queue/archive' }
    @{ Cat = 'DeliveryOpt';      Tier = 'SAFE';      Paths = @("$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"); Note = 'peer update cache' }
    @{ Cat = 'WUCache';          Tier = 'SAFE';      Paths = @("$env:SystemRoot\SoftwareDistribution\Download"); Note = 'skipped if a reboot is pending' }
    @{ Cat = 'NvidiaInstallers'; Tier = 'SAFE';      Paths = @("$PD\NVIDIA Corporation\Downloader", "$env:SystemDrive\NVIDIA"); Note = 'old driver packages' }
    @{ Cat = 'CrashDumps';       Tier = 'OPT-IN';    Paths = @("$L\CrashDumps", "$env:SystemRoot\Minidump", "$env:SystemRoot\MEMORY.DMP", "$env:SystemRoot\LiveKernelReports"); Note = 'evidence first: check the bugcheck section before deleting' }
    @{ Cat = 'DevCaches';        Tier = 'OPT-IN';    Paths = @("$L\pip\cache", "$L\npm-cache", "$L\uv\cache", "$L\Yarn\Cache", "$U\.nuget\packages"); Note = 'pip/npm/uv/yarn/nuget; installed envs unaffected' }
    @{ Cat = 'BrowserCache';     Tier = 'OPT-IN';    Paths = @($BrowserCacheDirs); Note = 'browsers must be closed' }
    @{ Cat = 'RecycleBin';       Tier = 'OPT-IN';    Paths = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { Join-Path $_.Root '$Recycle.Bin' }); Note = 'permanent' }
    @{ Cat = 'ComponentStore';   Tier = 'OPT-IN';    Paths = @("$env:SystemRoot\WinSxS"); Note = 'DISM StartComponentCleanup; on-disk size overstates (hardlinks)' }
    @{ Cat = 'Hibernation';      Tier = 'OPT-IN';    Paths = @("$env:SystemDrive\hiberfil.sys"); Note = 'powercfg /h off; also disables Fast Startup' }
    @{ Cat = 'Ollama models';    Tier = 'PROTECTED'; Paths = @($OllamaModels); Note = 'prune with: ollama rm <model>' }
    @{ Cat = 'HF/torch cache';   Tier = 'PROTECTED'; Paths = @("$U\.cache\huggingface", "$U\.cache\torch"); Note = 'may back live ComfyUI/Whisper loads' }
    @{ Cat = 'Downloads';        Tier = 'PROTECTED'; Paths = @("$U\Downloads"); Note = 'see largest-files list' }
    @{ Cat = 'Shader caches';    Tier = 'INFO';      Paths = @("$L\NVIDIA\DXCache", "$L\NVIDIA\GLCache", "$L\D3DSCache"); Note = 'rebuilds on next launch; clearing buys nothing' }
    @{ Cat = 'Windows.old';      Tier = 'INFO';      Paths = @("$env:SystemDrive\Windows.old", "$env:SystemDrive\`$WINDOWS.~BT"); Note = 'remove via Settings > System > Storage' }
    @{ Cat = 'Pagefile';         Tier = 'INFO';      Paths = @("$env:SystemDrive\pagefile.sys"); Note = 'leave system-managed' }
) + @($UserProtected | ForEach-Object { @{ Cat = $_.Name; Tier = 'PROTECTED'; Paths = $_.Paths; Note = $_.Note } }) |
    ForEach-Object { [pscustomobject]$_ }

# Every PROTECTED path, normalised with a trailing separator, for prefix checks during cleanup.
# Fail closed: a protected path that cannot be normalised must stop the run, not drop out of the guard.
$ProtectedRoots = foreach ($pp in @($Targets | Where-Object Tier -eq 'PROTECTED' | ForEach-Object { $_.Paths } | Where-Object { $_ })) {
    try { [IO.Path]::GetFullPath([string]$pp).TrimEnd('\') + '\' }
    catch {
        Write-Host " PROTECTED path '$pp' is not a valid path: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ' Refusing to run with an incomplete set of protected folders.' -ForegroundColor Red
        Stop-Transcript -ErrorAction SilentlyContinue -WhatIf:$false | Out-Null
        exit 2
    }
}
$ProtectedRoots = @($ProtectedRoots)
function Test-UnderProtected([string]$FullPath) {
    $p = [IO.Path]::GetFullPath($FullPath).TrimEnd('\') + '\'
    foreach ($r in $ProtectedRoots) { if ($p.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    $false
}

# ---------------------------------------------------------------- 1. system snapshot
Write-Section "Alpheus audit - $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
if (-not $IsAdmin) { Write-Host ' Not elevated: system paths, disk reliability, VSS and DISM checks will be partial.' -ForegroundColor Yellow }
Write-Host " Mode: $(if ($Apply) { if ($WhatIfPreference) { 'APPLY (WhatIf)' } else { 'APPLY' } } else { 'AUDIT (read-only)' })"
Write-Host " Log : $LogPath"

$os  = Get-CimInstance Win32_OperatingSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$bios = Get-CimInstance Win32_BIOS
$uptime = (Get-Date) - $os.LastBootUpTime
$Findings = [System.Collections.Generic.List[string]]::new()

Write-Section 'System'
"{0,-22}{1}" -f 'OS', "$($os.Caption) build $($os.BuildNumber)"
"{0,-22}{1}" -f 'CPU', $cpu.Name.Trim()
"{0,-22}{1}" -f 'BIOS', "$($bios.SMBIOSBIOSVersion) ($($bios.ReleaseDate.ToString('yyyy-MM-dd')))"
"{0,-22}{1:N1} days (since {2:yyyy-MM-dd HH:mm})" -f 'Uptime', $uptime.TotalDays, $os.LastBootUpTime
$ramTotal = $os.TotalVisibleMemorySize * 1KB; $ramFree = $os.FreePhysicalMemory * 1KB
"{0,-22}{1} used of {2}" -f 'RAM', (Format-Size ($ramTotal - $ramFree)), (Format-Size $ramTotal)
$commitTotal = $os.TotalVirtualMemorySize * 1KB; $commitFree = $os.FreeVirtualMemory * 1KB
"{0,-22}{1} of {2}" -f 'Commit', (Format-Size ($commitTotal - $commitFree)), (Format-Size $commitTotal)

# Microcode - Raptor Lake Vmin-shift instability (13th/14th gen desktop)
$mc = $null; $mcNote = $null
$cpuKey = Get-Item 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction SilentlyContinue
$mcSource = $null
if ($cpuKey) {
    foreach ($vn in 'Update Revision', 'Update Signature') {
        $ucode = $cpuKey.GetValue($vn)
        if ($ucode -is [byte[]] -and $ucode.Length -ge 8) { $mc = [BitConverter]::ToUInt32($ucode, 4); $mcSource = $vn; break }
        if ($ucode -is [byte[]] -and $ucode.Length -ge 4) { $mc = [BitConverter]::ToUInt32($ucode, 0); $mcSource = $vn; break }
    }
}
if ($null -eq $mc) {
    $names = if ($cpuKey) { ($cpuKey.GetValueNames() -join ', ') } else { 'key unreadable' }
    $mcNote = "unavailable - CentralProcessor\0 values: $names"
    "{0,-22}{1}" -f 'Microcode (loaded)', $mcNote
}
if ($null -ne $mc) {
    "{0,-22}0x{1:X}  ({2})" -f 'Microcode (loaded)', $mc, $mcSource
    if ($cpu.Name -match 'i[3579]-1[34]\d{3}' -and $mc -lt 0x12B) {
        $Findings.Add("CPU microcode 0x$('{0:X}' -f $mc) is below 0x12B on a 13th/14th-gen part. Update BIOS before anything else - this is a degradation issue, not a speed tweak.")
    }
}

$pending = Test-PendingReboot
"{0,-22}{1}" -f 'Reboot pending', $pending
if ($pending) { $Findings.Add('A reboot is pending. Updates are staged and holding files; reboot before judging performance.') }
if ($uptime.TotalDays -gt 30) { $Findings.Add("Uptime $([int]$uptime.TotalDays) days. Long uptimes on Win11 accumulate driver/handle leaks; a reboot is the cheapest fix there is.") }

$plan = (powercfg.exe /getactivescheme) -replace '^.*\((.+)\).*$', '$1'
"{0,-22}{1}" -f 'Power plan', $plan
# Absent values are normal (Windows default in force); reading .Name off a null result throws under StrictMode.
function Get-RegValue([string]$Key, [string]$Name) { try { Get-ItemPropertyValue -LiteralPath $Key -Name $Name -ErrorAction Stop } catch { $null } }
$hags = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
"{0,-22}{1}" -f 'HW GPU scheduling', $(switch ($hags) { 2 { 'On' } 1 { 'Off' } default { 'Default' } })
$gm = Get-RegValue 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled'
"{0,-22}{1}" -f 'Game Mode', $(if ($gm -eq 0) { 'Off' } else { 'On' })

# ---------------------------------------------------------------- 2. stability signals
Write-Section 'Stability (last 30 days)'
$since = (Get-Date).AddDays(-30)
$kp41  = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41; StartTime = $since } -ErrorAction SilentlyContinue)
$whea  = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $since } -ErrorAction SilentlyContinue)
$bugs  = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $since } -ErrorAction SilentlyContinue)
"{0,-30}{1}" -f 'Unexpected shutdowns (41)', $kp41.Count
"{0,-30}{1}" -f 'WHEA hardware errors', $whea.Count
"{0,-30}{1}" -f 'Bugchecks (1001)', $bugs.Count
foreach ($b in ($bugs | Select-Object -First 5)) {
    $code = if ($b.Message -match '0x[0-9a-fA-F]{8}') { $Matches[0] } else { '?' }
    "    {0:yyyy-MM-dd HH:mm}  {1}" -f $b.TimeCreated, $code
}
if ($whea.Count -gt 0) { $Findings.Add("$($whea.Count) WHEA event(s) in 30 days. On a 13th/14th-gen Intel CPU treat as possible degradation or unstable memory/XMP until ruled out.") }
if (($kp41.Count + $bugs.Count) -gt 0) { $Findings.Add('Unexpected shutdowns or bugchecks present. Keep the crash dumps (do not run -Include CrashDumps) until you have read them.') }

# ---------------------------------------------------------------- 3. storage
Write-Section 'Volumes'
$vols = Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter } | Sort-Object DriveLetter
$vols | ForEach-Object {
    $pct = if ($_.Size) { 100 * $_.SizeRemaining / $_.Size } else { 0 }
    if ($pct -lt 15) { $Findings.Add("Volume $($_.DriveLetter): is at $([int]$pct)% free. Below ~15% NTFS fragmentation and SSD write amplification start to cost you.") }
    [pscustomobject]@{
        Drive = "$($_.DriveLetter):"; Label = $_.FileSystemLabel; FS = $_.FileSystem
        Size = Format-Size ([long]$_.Size); Free = Format-Size ([long]$_.SizeRemaining); 'Free%' = '{0:N0}' -f $pct
    }
} | Format-Table -AutoSize | Out-Host

Write-Section 'Physical disks'
Get-PhysicalDisk | ForEach-Object {
    $rc = if ($IsAdmin) { $_ | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue } else { $null }
    if ($rc -and $rc.Wear -ge 80) { $Findings.Add("Disk '$($_.FriendlyName)' reports $($rc.Wear)% wear. Plan replacement.") }
    if ($_.HealthStatus -ne 'Healthy') { $Findings.Add("Disk '$($_.FriendlyName)' health is $($_.HealthStatus).") }
    [pscustomobject]@{
        Disk = $_.FriendlyName; Type = $_.MediaType; Bus = $_.BusType; Size = Format-Size ([long]$_.Size)
        Health = $_.HealthStatus
        'Temp C' = if ($rc) { $rc.Temperature } else { '-' }
        'Wear%'  = if ($rc) { $rc.Wear } else { '-' }
    }
} | Format-Table -AutoSize | Out-Host
$trim = (fsutil.exe behavior query DisableDeleteNotify) -join ' '
Write-Host " TRIM: $trim"
if ($trim -match 'NTFS DisableDeleteNotify = 1') { $Findings.Add('TRIM is disabled for NTFS. Re-enable: fsutil behavior set DisableDeleteNotify 0') }

Write-Section 'Cleanup targets'
$Report = foreach ($t in $Targets) {
    foreach ($p in $t.Paths) {
        if (-not $p) { continue }
        $size = Get-PathSize $p
        if ($null -eq $size) { continue }
        [pscustomobject]@{ Tier = $t.Tier; Category = $t.Cat; SizeBytes = $size; Size = Format-Size $size; Path = $p; Note = $t.Note }
    }
}
$TierRank = @{ SAFE = 0; 'OPT-IN' = 1; PROTECTED = 2; INFO = 3 }
$Report | Sort-Object @{ e = { $TierRank[$_.Tier] }; Ascending = $true }, @{ e = 'SizeBytes'; Descending = $true } |
    Format-Table Tier, Category, Size, Path, Note -AutoSize -Wrap | Out-Host

# Summed by hand: Measure-Object emits nothing for empty input, and .Sum on that throws under StrictMode
# (a category with no measured paths, e.g. NvidiaInstallers when neither folder exists).
function Get-ReportBytes([string]$Property, [string]$Value) {
    $sum = 0L
    foreach ($r in @($Report | Where-Object { $_.$Property -eq $Value })) { $sum += [long]$r.SizeBytes }
    $sum
}
function Get-CategoryBytes([string]$Cat) { Get-ReportBytes 'Category' $Cat }

$safeTotal = Get-ReportBytes 'Tier' 'SAFE'
$optTotal  = Get-ReportBytes 'Tier' 'OPT-IN'
Write-Host (" SAFE set reclaimable : {0}" -f (Format-Size $safeTotal)) -ForegroundColor Green
Write-Host (" OPT-IN on the table  : {0}  (WinSxS figure overstates - hardlinks)" -f (Format-Size $optTotal)) -ForegroundColor Yellow

# Virtual disks that only ever grow
$vhdx = @(Get-ChildItem "$L\Packages\*\LocalState\ext4.vhdx" -Force -ErrorAction SilentlyContinue) +
        @(Get-ChildItem "$L\Docker\wsl" -Recurse -Filter *.vhdx -Force -ErrorAction SilentlyContinue)
if ($vhdx) {
    Write-Host "`n WSL/Docker virtual disks (grow-only; compact by hand after wsl --shutdown):"
    $vhdx | ForEach-Object { "    {0,10}  {1}" -f (Format-Size $_.Length), $_.FullName }
}

foreach ($up in @($UserProtected | Where-Object Breakdown)) {
    foreach ($bp in $up.Paths) {
        if (-not (Test-Path -LiteralPath $bp -PathType Container)) { continue }
        Write-Host "`n $bp breakdown (PROTECTED - for hand pruning):"
        Get-ChildItem -LiteralPath $bp -Force -ErrorAction SilentlyContinue |
            ForEach-Object { [pscustomobject]@{ Name = $_.Name; Bytes = (Get-PathSize $_.FullName) } } |
            Sort-Object Bytes -Descending | Select-Object -First 15 |
            ForEach-Object { "    {0,10}  {1}" -f (Format-Size $_.Bytes), $_.Name }
    }
}
if (Get-Command ollama -ErrorAction SilentlyContinue) {
    Write-Host "`n ollama list:"
    ollama list 2>$null | ForEach-Object { "    $_" }
}

if ($IsAdmin) {
    Write-Host "`n Shadow copy storage:"
    (vssadmin.exe list shadowstorage) | Where-Object { $_ -match 'volume|Used|Allocated|Maximum' } | ForEach-Object { "    $($_.Trim())" }
}

Write-Section 'Largest files in profile (>= 1 GB)'
$big = [System.Collections.Generic.List[object]]::new()
try {
    foreach ($f in [System.IO.DirectoryInfo]::new($U).EnumerateFiles('*', (New-EnumOptions))) {
        if ($f.Length -ge 1GB) { $big.Add($f) }
    }
} catch { }
$big | Sort-Object Length -Descending | Select-Object -First 25 | ForEach-Object {
    "{0,10}  {1:yyyy-MM-dd}  {2}" -f (Format-Size $_.Length), $_.LastWriteTime, $_.FullName
}
if (-not $big.Count) { ' none' }

if ($Deep) {
    foreach ($v in $vols) {
        Write-Section "Top-level folders on $($v.DriveLetter):\ (Deep)"
        Get-ChildItem "$($v.DriveLetter):\" -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
            ForEach-Object { [pscustomobject]@{ Name = $_.FullName; Bytes = (Get-PathSize $_.FullName) } } |
            Sort-Object Bytes -Descending | Select-Object -First 20 |
            ForEach-Object { "{0,10}  {1}" -f (Format-Size $_.Bytes), $_.Name }
    }
    if ($IsAdmin) {
        Write-Section 'Component store analysis (Deep)'
        dism.exe /Online /Cleanup-Image /AnalyzeComponentStore | Where-Object { $_ -match 'Size|Reclaimable|Recommended|Date' }
    }
}

# ---------------------------------------------------------------- 4. performance
Write-Section 'Top 12 processes by RAM'
Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 12 |
    Format-Table @{ n = 'Name'; e = { $_.ProcessName } }, Id,
        @{ n = 'RAM'; e = { Format-Size $_.WorkingSet64 } },
        @{ n = 'CPU s'; e = { '{0:N0}' -f $_.CPU } } -AutoSize | Out-Host

Write-Section 'GPU dedicated memory per process (MiB)'
# Per-process counter, not NVML: NVML returns nothing per-process on this WDDM display card.
$gpu = (Get-Counter '\GPU Process Memory(*)\Dedicated Usage' -ErrorAction SilentlyContinue).CounterSamples |
    Where-Object { $_.CookedValue -gt 0 } |
    ForEach-Object {
        $procId = if ($_.InstanceName -match 'pid_(\d+)_') { [int]$Matches[1] } else { 0 }
        [pscustomobject]@{ ProcId = $procId; Bytes = $_.CookedValue }
    } | Group-Object ProcId | ForEach-Object {
        $p = Get-Process -Id ([int]$_.Name) -ErrorAction SilentlyContinue
        [pscustomobject]@{ PID = [int]$_.Name; Name = if ($p) { $p.ProcessName } else { '<exited>' }
                           MiB = [math]::Round(($_.Group | Measure-Object Bytes -Sum).Sum / 1MB) }
    } | Sort-Object MiB -Descending | Select-Object -First 10
if ($gpu) { $gpu | Format-Table -AutoSize | Out-Host } else { ' counter unavailable' }
$holders = @($gpu | Where-Object { $_.Name -match 'ollama|llama|kobold' -and $_.MiB -gt 500 })
foreach ($h in $holders) {
    $age = try { '{0:N1} h' -f ((Get-Date) - (Get-Process -Id $h.PID -ErrorAction Stop).StartTime).TotalHours } catch { '?' }
    $how = switch -Regex ($h.Name) {
        'ollama'       { "release with 'ollama stop <model>'; Stop-Process on the tray orphans the runner" }
        'llama-server' { 'Ctrl+C in its console (or its launcher''s stop path) releases cleanly; check its command line to see which model' }
        'kobold'       { 'close it from KoboldCpp or its launcher' }
        default        { 'stop it from whatever launched it' }
    }
    $Findings.Add("$($h.Name) (PID $($h.PID), up $age) holds $($h.MiB) MiB of the 16 GB card. If it is not loaded on purpose, $how. Anything else wanting the GPU (ComfyUI, games) contends with it until then.")
}

Write-Section 'Startup commands'
Get-CimInstance Win32_StartupCommand | Sort-Object Name |
    Format-Table Name, @{ n = 'Location'; e = { $_.Location -replace '^HKU\\S-[\d-]+', 'HKCU' } },
        @{ n = 'Command'; e = { $c = "$($_.Command)"; if ($c.Length -gt 70) { $c.Substring(0, 70) + '...' } else { $c } } } -AutoSize | Out-Host
Write-Host ' (Task Manager > Startup apps shows which of these are already disabled.)' -ForegroundColor DarkGray

Write-Section 'Third-party auto-start services'
Get-CimInstance Win32_Service -Filter "StartMode='Auto'" |
    Where-Object { $_.PathName -and $_.PathName -notmatch '(?i)\\Windows\\' } |
    Sort-Object State, Name |
    Format-Table Name, State, @{ n = 'Binary'; e = { ($_.PathName -replace '"', '') -replace '\s+-.*$', '' } } -AutoSize | Out-Host

# ---------------------------------------------------------------- 5. apply
$Freed = [ordered]@{}
if ($Apply) {
    Write-Section "Apply: $(($Selected | Sort-Object) -join ', ')"
    $needsAdmin = 'WER', 'DeliveryOpt', 'WUCache', 'NvidiaInstallers', 'ComponentStore', 'Hibernation', 'RecycleBin'
    foreach ($cat in ($SafeSet + $OptSet)) {
        if (-not $Selected.Contains($cat)) { continue }
        if (-not $IsAdmin -and $cat -in $needsAdmin) { Write-Host " [$cat] skipped - needs elevation" -ForegroundColor Yellow; continue }
        # A category whose own folder is PROTECTED is skipped whole: its tool commands (uv/npm/pip cache
        # clean, DISM, powercfg) do not go through the per-file guard in Clear-PathContents.
        $hit = @(($Targets | Where-Object Cat -eq $cat).Paths | Where-Object { $_ -and (Test-UnderProtected $_) })
        if ($hit.Count) { Write-Host " [$cat] skipped - $($hit[0]) is PROTECTED" -ForegroundColor Yellow; continue }
        $before = Get-CategoryBytes $cat
        if (-not $PSCmdlet.ShouldProcess("$cat (measured $(Format-Size $before))", 'Clean')) { continue }
        $done = 0L
        switch ($cat) {
            'Temp' {
                $done += Clear-PathContents $env:TEMP $TempAgeDays
                if ($IsAdmin) { $done += Clear-PathContents "$env:SystemRoot\Temp" $TempAgeDays }
            }
            'WER' {
                foreach ($p in ($Targets | Where-Object Cat -eq 'WER').Paths) { $done += Clear-PathContents $p }
            }
            'DeliveryOpt' {
                if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
                    Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue | Out-Null
                    $done = $before - [long](Get-PathSize ($Targets | Where-Object Cat -eq 'DeliveryOpt').Paths[0])
                }
            }
            'WUCache' {
                if (Test-PendingReboot) { Write-Host ' [WUCache] skipped - reboot pending; staged updates may live here' -ForegroundColor Yellow; break }
                Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue
                $done += Clear-PathContents "$env:SystemRoot\SoftwareDistribution\Download"
                Start-Service bits, wuauserv -ErrorAction SilentlyContinue
            }
            'NvidiaInstallers' {
                foreach ($p in ($Targets | Where-Object Cat -eq 'NvidiaInstallers').Paths) { $done += Clear-PathContents $p }
            }
            'CrashDumps' {
                if (($kp41.Count + $bugs.Count + $whea.Count) -gt 0 -and -not $Force) {
                    $ok = $false
                    try { $ok = $PSCmdlet.ShouldContinue('Recent crashes/WHEA events exist. Delete the dumps anyway?', 'CrashDumps') }
                    catch { Write-Host ' [CrashDumps] skipped - recent crashes and no -Force in a non-interactive run' -ForegroundColor Yellow }
                    if (-not $ok) { break }
                }
                foreach ($p in ($Targets | Where-Object Cat -eq 'CrashDumps').Paths) {
                    if (Test-Path -LiteralPath $p -PathType Leaf) {
                        $s = (Get-Item -LiteralPath $p -Force).Length
                        Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
                        if (-not (Test-Path -LiteralPath $p)) { $done += $s }
                    } else { $done += Clear-PathContents $p }
                }
            }
            'DevCaches' {
                if (Get-Command pip -ErrorAction SilentlyContinue) { pip cache purge 2>&1 | Out-Null }
                if (Get-Command npm -ErrorAction SilentlyContinue) { npm cache clean --force 2>&1 | Out-Null }
                if (Get-Command uv  -ErrorAction SilentlyContinue) { uv cache clean 2>&1 | Out-Null }
                foreach ($p in ($Targets | Where-Object Cat -eq 'DevCaches').Paths) { $done += Clear-PathContents $p }
                $done = [math]::Max($done, $before - (($Targets | Where-Object Cat -eq 'DevCaches').Paths | ForEach-Object { [long](Get-PathSize $_) } | Measure-Object -Sum).Sum)
            }
            'BrowserCache' {
                $running = Get-Process chrome, msedge, brave -ErrorAction SilentlyContinue
                if ($running) { Write-Host " [BrowserCache] skipped - close: $(($running.ProcessName | Sort-Object -Unique) -join ', ')" -ForegroundColor Yellow; break }
                foreach ($p in $BrowserCacheDirs) { $done += Clear-PathContents $p }
            }
            'RecycleBin' {
                if (Get-Command Clear-RecycleBin -ErrorAction SilentlyContinue) {
                    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
                    $done = $before
                } else { Write-Host ' [RecycleBin] Clear-RecycleBin unavailable in this shell' -ForegroundColor Yellow }
            }
            'ComponentStore' {
                $free0 = (Get-Volume -DriveLetter $env:SystemDrive[0]).SizeRemaining
                $dismArgs = @('/Online', '/Cleanup-Image', '/StartComponentCleanup') + $(if ($ResetBase) { '/ResetBase' } else { @() })
                Write-Host " [ComponentStore] dism $($dismArgs -join ' ')  (several minutes)"
                & dism.exe @dismArgs | Where-Object { $_ -match '\d+(\.\d+)?%|completed|Error' } | Select-Object -Last 3
                $done = [math]::Max(0, (Get-Volume -DriveLetter $env:SystemDrive[0]).SizeRemaining - $free0)
            }
            'Hibernation' {
                powercfg.exe /hibernate off
                $done = if (Test-Path "$env:SystemDrive\hiberfil.sys") { 0 } else { $before }
            }
        }
        $Freed[$cat] = [long]$done
        Write-Host (" [{0}] freed {1}" -f $cat, (Format-Size $done)) -ForegroundColor Green
    }
    $tot = ($Freed.Values | Measure-Object -Sum).Sum
    Write-Host (" Total freed: {0}" -f (Format-Size $tot)) -ForegroundColor Green
}

# ---------------------------------------------------------------- 6. findings + export
Write-Section 'Findings'
if ($Findings.Count) { $Findings | ForEach-Object { " - $_" } } else { ' nothing flagged' }
if (-not $Apply) { Write-Host "`n Audit only. Nothing was changed. Re-run with -Apply -WhatIf to preview cleanup." -ForegroundColor Cyan }

[pscustomobject]@{
    Host = $env:COMPUTERNAME; When = (Get-Date).ToString('o'); Admin = $IsAdmin; Mode = $(if ($Apply) { 'apply' } else { 'audit' })
    Microcode = if ($null -ne $mc) { '0x{0:X} ({1})' -f $mc, $mcSource } elseif ($mcNote) { $mcNote } else { 'not read' }
    Volumes = $vols | ForEach-Object { @{ Drive = "$($_.DriveLetter):"; Label = $_.FileSystemLabel; SizeGB = [math]::Round($_.Size / 1GB, 1); FreeGB = [math]::Round($_.SizeRemaining / 1GB, 1) } }
    Disks = Get-PhysicalDisk | ForEach-Object { @{ Name = $_.FriendlyName; Media = "$($_.MediaType)"; Bus = "$($_.BusType)"; SizeGB = [math]::Round($_.Size / 1GB) } }
    Targets = $Report | Select-Object Tier, Category, SizeBytes, Path
    Freed = $Freed; Findings = $Findings
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $JsonPath -Encoding utf8 -WhatIf:$false

Write-Host "`n JSON: $JsonPath"
Stop-Transcript -ErrorAction SilentlyContinue -WhatIf:$false | Out-Null   # -WhatIf runs must still close the log
