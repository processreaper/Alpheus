#Requires -Version 7.0
<#
.SYNOPSIS
    Tests Acheron (delete on the Disk usage tab) against a throwaway %TEMP% sandbox, never real data.

.DESCRIPTION
    Runs the real GUI script with ShowDialog replaced by a scripted session. The two dialog functions
    (Show-DeleteConfirm / Show-DeleteInfo) are replaced by recorders that answer from a queue, so every
    dialog's exact text is checked. Recycled sandbox items are removed from the Recycle Bin afterwards
    (matched by original location inside the sandbox only).
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = '$HSB and $HGuiDir are read by the harness scriptblock built from text, which the analyzer cannot see')]
param([string]$Gui = (Join-Path (Split-Path $PSScriptRoot) 'Start-AlpheusGui.ps1'))
$src = (Get-Content -LiteralPath $Gui -Raw).Replace('#Requires -Version 7.0', '').Replace('param([switch]$NoElevate)', '$NoElevate = $true')
$tail = '[void]$Win.ShowDialog()'
$src = $src.TrimEnd(); if (-not $src.EndsWith($tail)) { throw 'unexpected script tail' }
# Script text run as a scriptblock has no $PSScriptRoot; point it at the GUI's folder (so its config applies).
$src = $src.Substring(0, $src.Length - $tail.Length).Replace('$PSScriptRoot', "'$(Split-Path $Gui)'")

# sandbox
$SB = Join-Path $env:TEMP ('alpheus-del-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
function NewFile($rel, $mb) { $f = Join-Path $SB $rel; $null = New-Item -ItemType Directory (Split-Path $f) -Force; [IO.File]::WriteAllBytes($f, [byte[]]::new([int]($mb * 1MB))) }
NewFile 'keep\model.bin' 2; NewFile 'junk1\a.bin' 3; NewFile 'junk2\b.bin' 2; NewFile 'junk2\c.bin' 1.5
NewFile 'loose.bin' 1.2; NewFile 'steamapps\common\FakeGame\g.bin' 1; NewFile 'gridonly\big.bin' 4

$harness = @'
$T = @{ Fail = 0; Answers = [Collections.Generic.Queue[bool]]::new(); Dialogs = [Collections.Generic.List[string]]::new() }
function Check([string]$what, [bool]$ok) { if (-not $ok) { $T.Fail++ }; [Console]::WriteLine(('{0}  {1}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $what)) }
function Show-DeleteConfirm([string]$text, [string]$title, [string]$icon) { $T.Dialogs.Add("[$title] $text"); if ($T.Answers.Count) { $T.Answers.Dequeue() } else { $false } }
function Show-DeleteInfo([string]$text, [string]$icon = 'Information') { $T.Dialogs.Add("[info] $text") }
function Pump { $f = [Windows.Threading.DispatcherFrame]::new(); [void][Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background, [Action]{ $f.Continue = $false }); [Windows.Threading.Dispatcher]::PushFrame($f) }
function ItemFor([string]$rel) {
    $want = Join-Path $HSB $rel
    $found = $null
    $walk = { param($items) foreach ($it in $items) { if ($it -is [Windows.Controls.TreeViewItem] -and $null -ne $it.Tag) { if ($it.Tag.FullPath -ieq $want) { $script:hit = $it }; Expand-NodeItem $it; $it.IsExpanded = $true; & $walk $it.Items } } }
    $script:hit = $null; & $walk $ui.tvDisk.Items; $script:hit
}
function Answer([bool[]]$a) { $T.Answers.Clear(); foreach ($x in $a) { $T.Answers.Enqueue($x) }; $T.Dialogs.Clear() }
function Rows { @($ui.gridBig.ItemsSource | ForEach-Object Path) }

$Win.Add_ContentRendered({
  try {
    # --- guard rules (real protections + this sandbox's keep\ added as PROTECTED)
    Initialize-DeleteGuard
    $script:ProtectedRoots += (Format-Root (Join-Path $HSB 'keep'))
    $cases = [ordered]@{
        "$env:SystemDrive\"                                  = 'drive root'
        "$env:SystemRoot\System32"                           = 'inside Windows'
        "$env:ProgramFiles"                                  = 'top-level'
        "$env:USERPROFILE"                                   = 'top-level'
        (Join-Path $env:USERPROFILE 'Downloads\x.zip')       = 'PROTECTED'
        "$env:SystemDrive\`$Recycle.Bin\S-1-5-x"             = 'Recycle Bin'
        "$env:SystemDrive\pagefile.sys"                      = 'system file'
        (Join-Path $HSB 'keep\model.bin')                    = 'PROTECTED'
        $HSB                                                 = 'contains PROTECTED'
        (Join-Path $HSB 'junk1')                             = ''
    }
    foreach ($k in $cases.Keys) { $r = Get-RefuseReason $k; Check ("guard {0,-52} -> {1}" -f $k, $(if ($r) { $r } else { 'allowed' })) $(if ($cases[$k]) { $r -match [regex]::Escape($cases[$k]) } else { -not $r }) }
    # every folder in the config file in force on this machine (if any) must be refused, and things inside it
    $cfgFile = @((Join-Path $HGuiDir 'alpheus.config.json'), (Join-Path $env:LOCALAPPDATA 'Alpheus\alpheus.config.json')) | Where-Object { Test-Path $_ } | Select-Object -First 1
    Check "delete enabled (config readable: $(if ($cfgFile) { $cfgFile } else { 'none' }))" (-not $script:DeleteBlocked)
    if ($cfgFile) {
        foreach ($pe in @((Get-Content $cfgFile -Raw | ConvertFrom-Json -AsHashtable).Protected)) {
            foreach ($raw in @($pe.Paths)) {
                $x = [Environment]::ExpandEnvironmentVariables($raw)
                Check "config-protected $x -> $(Get-RefuseReason $x)" ((Get-RefuseReason $x) -eq 'PROTECTED' -and (Get-RefuseReason (Join-Path $x 'anything')) -eq 'PROTECTED')
            }
        }
    }

    # --- scan the sandbox
    $ui.tabs.SelectedIndex = 3; Start-DiskScan $HSB
    while (-not ($script:Scanner.IsCompleted -and $ui.btnScan.IsEnabled)) { Pump; Start-Sleep -Milliseconds 50 }
    $before = $script:Scanner.Root.Size

    # 1. recycle two marked items
    Clear-Mark; Set-Mark (ItemFor 'junk1') $true; Set-Mark (ItemFor 'loose.bin') $true
    Answer @($true); Invoke-DiskDelete 'tree' $false
    $d = $T.Dialogs[0]
    Check 'recycle: one confirmation listing both items + total' ($T.Dialogs.Count -eq 1 -and $d -match 'junk1' -and $d -match 'loose\.bin' -and $d -match 'Move to the Recycle Bin 2 item' -and $d -match '4\.2 MB')
    Check 'recycle: both gone from disk' (-not (Test-Path (Join-Path $HSB 'junk1')) -and -not (Test-Path (Join-Path $HSB 'loose.bin')))
    Check "recycle: tree total shrank by 4.2 MB ($before -> $($script:Scanner.Root.Size))" (($before - $script:Scanner.Root.Size) -eq [long](4.2MB))
    Check 'recycle: rows gone from tree' (-not (ItemFor 'junk1') -and -not (ItemFor 'loose.bin'))
    $log = @(Get-Content $DeleteLog -Tail 2)
    Check 'recycle: both logged as RECYCLE OK' (@($log | Where-Object { $_ -match "`tRECYCLE`tOK`t" -and $_ -match [regex]::Escape($HSB) }).Count -eq 2)

    # 2. mixed selection: protected item refused and listed; answer No -> nothing happens
    Clear-Mark; Set-Mark (ItemFor 'junk2') $true; Set-Mark (ItemFor 'keep') $true
    Answer @($false); Invoke-DiskDelete 'tree' $false
    $d = $T.Dialogs[0]
    Check 'mixed: keep\ listed under "Will NOT be touched" as PROTECTED' ($d -match 'Will NOT be touched:[\s\S]*keep[\s\S]*PROTECTED')
    Check 'mixed: answered No -> junk2 still there' (Test-Path (Join-Path $HSB 'junk2\b.bin'))

    # 3. permanent: second confirmation No -> nothing deleted
    Clear-Mark; Set-Mark (ItemFor 'junk2') $true
    Answer @($true, $false); Invoke-DiskDelete 'tree' $true
    Check 'permanent: two confirmations, second says no Recycle Bin copy' ($T.Dialogs.Count -eq 2 -and $T.Dialogs[0] -match 'PERMANENTLY DELETE' -and $T.Dialogs[1] -match 'no Recycle Bin copy')
    Check 'permanent: second No -> junk2 still there' (Test-Path (Join-Path $HSB 'junk2'))

    # 4. permanent: Yes, Yes -> gone, not in the bin
    Clear-Mark; Set-Mark (ItemFor 'junk2') $true
    Answer @($true, $true); Invoke-DiskDelete 'tree' $true
    Check 'permanent: junk2 gone' (-not (Test-Path (Join-Path $HSB 'junk2')))

    # 5. Steam game warning
    Clear-Mark; Set-Mark (ItemFor 'steamapps\common\FakeGame') $true
    Answer @($false); Invoke-DiskDelete 'tree' $false
    Check 'steam: warning suggests uninstalling in Steam' ($T.Dialogs[0] -match 'Steam game: uninstalling in Steam')

    # 6. scan root and aggregate groups are refused
    Clear-Mark; Set-Mark $ui.tvDisk.Items[0] $true
    Answer @(); Invoke-DiskDelete 'tree' $false
    Check 'root: refused with info, no confirmation' ($T.Dialogs.Count -eq 1 -and $T.Dialogs[0] -match '^\[info\] Nothing can be deleted' -and $T.Dialogs[0] -match 'scan root')

    # 7. from the Largest files grid
    $row = @($ui.gridBig.ItemsSource | Where-Object { $_.Path -like '*gridonly*big.bin' })[0]
    $ui.gridBig.SelectedItems.Clear(); [void]$ui.gridBig.SelectedItems.Add($row)
    Answer @($true); Invoke-DiskDelete 'grid' $false
    Check 'grid: selected row deleted' (-not (Test-Path (Join-Path $HSB 'gridonly\big.bin')))
    Check 'grid: row removed from Largest files' (-not ((Rows) -match 'gridonly'))
    Check "treemap root still attached ($($script:TmRoot.FullPath))" ([Alpheus.Scanner]::IsAttached($script:TmRoot, $script:Scanner.Root))

    [Console]::WriteLine("errors in session: $($Error.Count)"); foreach ($e in $Error) { [Console]::WriteLine("ERR: $($e | Out-String)") }
  } catch { $T.Fail++; [Console]::WriteLine("HARNESS EXCEPTION: $($_ | Out-String)") }
  $script:TFail = $T.Fail
  $Win.Close()
})
[void]$Win.ShowDialog()
'@
$HSB = $SB; $HGuiDir = Split-Path $Gui; $Error.Clear()
. ([scriptblock]::Create($src + "`n" + $harness))

# tidy: our recycled items out of the bin (matched by original location), then the sandbox
$bin = (New-Object -ComObject Shell.Application).NameSpace(10)
$ours = @($bin.Items() | Where-Object { $bin.GetDetailsOf($_, 1) -like "$SB*" })
"recycled sandbox items found in the Recycle Bin: $($ours.Count) (expect 3: junk1, loose.bin, big.bin)"
if ($ours.Count -ne 3) { $script:TFail++ }
foreach ($it in $ours) { Remove-Item -LiteralPath $it.Path -Recurse -Force -ErrorAction SilentlyContinue }
Remove-Item -LiteralPath $SB -Recurse -Force -ErrorAction SilentlyContinue
"`n$(if ($script:TFail) { "$($script:TFail) FAILED" } else { 'ALL PASSED' })"
exit [int]$script:TFail
