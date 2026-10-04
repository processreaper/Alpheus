#Requires -Version 7.0
<#
.SYNOPSIS
    Exercises dist\Alpheus.exe without a UAC prompt (--no-elevate), from outside via UI Automation:
    missing-pwsh dialog, first-run unpack, GUI starts with no console and its icon, a scan works,
    a tampered unpacked file is repaired, and older version folders are removed.
#>
param([string]$Exe = (Join-Path (Split-Path $PSScriptRoot) 'dist\Alpheus.exe'))
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace T -Name W -MemberDefinition '[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);'
$A = [Windows.Automation.AutomationElement]; $S = [Windows.Automation.TreeScope]
$version = (Get-Item $Exe).VersionInfo.ProductVersion
$app = Join-Path $env:LOCALAPPDATA "Alpheus\app\$version"
$fail = 0
function Check([string]$what, [bool]$ok) { '{0}  {1}' -f $(if ($ok) { 'PASS' } else { $script:fail++; 'FAIL' }), $what }
function WaitWindow([scriptblock]$match, [int]$sec = 20) {
    $end = (Get-Date).AddSeconds($sec)
    while ((Get-Date) -lt $end) {
        $w = $A::RootElement.FindAll($S::Children, [Windows.Automation.Condition]::TrueCondition) | Where-Object { & $match $_ } | Select-Object -First 1
        if ($w) { return $w }; Start-Sleep -Milliseconds 300
    }
}

# 1. PowerShell 7 missing -> explanatory dialog, exit 1
$env:ALPHEUS_PWSH = 'C:\nonexistent\pwsh.exe'
$p = Start-Process $Exe -PassThru; $null = $p.Handle   # touch the handle now, or ExitCode is lost after exit
$dlg = WaitWindow { param($w) $w.Current.ProcessId -eq $p.Id }
$noBtn = $null; $txt = ''
for ($i = 0; $dlg -and $i -lt 30 -and -not $noBtn; $i++) {   # the window exists before its controls do
    Start-Sleep -Milliseconds 200
    $noBtn = $dlg.FindFirst($S::Descendants, [Windows.Automation.AndCondition]::new(
        [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, [Windows.Automation.ControlType]::Button),
        [Windows.Automation.PropertyCondition]::new($A::NameProperty, 'No')))
}
if ($dlg) { $txt = ($dlg.FindAll($S::Descendants, [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, [Windows.Automation.ControlType]::Text)) | ForEach-Object { $_.Current.Name }) -join ' ' }
Check "missing pwsh: dialog '$($dlg.Current.Name)' explains winget install" ($null -ne $dlg -and $txt -match 'winget install --id Microsoft\.PowerShell')
if ($noBtn) { $noBtn.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke() }
$p.WaitForExit(5000) | Out-Null; Check "missing pwsh: exit code 1 (got $($p.ExitCode))" ($p.ExitCode -eq 1)
Remove-Item Env:\ALPHEUS_PWSH

# 2. first run: unpack, old versions removed, GUI with icon and no console
if (Test-Path $app) { Remove-Item $app -Recurse -Force }
$stale = Join-Path $env:LOCALAPPDATA 'Alpheus\app\0.0.1'; $null = New-Item -ItemType Directory $stale -Force
$p = Start-Process $Exe -ArgumentList '--no-elevate' -PassThru; $null = $p.Handle; $p.WaitForExit(15000) | Out-Null
Check "launcher exits after starting the GUI (exit $($p.ExitCode))" ($p.ExitCode -eq 0)
Check "unpacked to $app" (@('Start-AlpheusGui.ps1', 'Invoke-Alpheus.ps1', 'alpheus.ico', 'LICENSE', 'README.md' | Where-Object { Test-Path (Join-Path $app $_) }).Count -eq 5)
Check 'stale version folder removed' (-not (Test-Path $stale))
$gui = WaitWindow { param($w) $w.Current.Name -eq "Alpheus - $env:COMPUTERNAME" } 30
Check 'GUI window appeared' ($null -ne $gui)
if ($gui) {
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($gui.Current.ProcessId)"
    Check "GUI runs from the unpacked copy ($($proc.Name))" ($proc.CommandLine -like "*$app*Start-AlpheusGui.ps1*")
    $hasVisibleConsole = [bool](Get-Process -Id $gui.Current.ProcessId).MainWindowTitle -ne "Alpheus - $env:COMPUTERNAME"
    Check 'no console window is the main window' (-not $hasVisibleConsole)
    $hIcon = [T.W]::SendMessage([IntPtr]$gui.Current.NativeWindowHandle, 0x7F, [IntPtr]1, [IntPtr]0)   # WM_GETICON, ICON_BIG
    Check 'window has its own icon (WM_GETICON)' ($hIcon -ne [IntPtr]::Zero)
    $tab = $gui.FindFirst($S::Descendants, [Windows.Automation.AndCondition]::new(
        [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, [Windows.Automation.ControlType]::TabItem),
        [Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Disk usage')))
    $tab.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select(); Start-Sleep -Milliseconds 400
    $gui.FindFirst($S::Descendants, [Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty, 'btnScan')).GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    $lbl = $null; for ($i = 0; $i -lt 120; $i++) { Start-Sleep -Milliseconds 500; $lbl = $gui.FindFirst($S::Descendants, [Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty, 'lblScan')).Current.Name; if ($lbl -match '^(Done|Scan failed|GUI error)') { break } }
    Check "scan from the exe build: $($lbl.Substring(0, [math]::Min(60, $lbl.Length)))" ($lbl -match '^Done')
    $gui.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close(); Start-Sleep 2
}

# 3. tampered unpacked script is repaired on next launch
$gs = Join-Path $app 'Start-AlpheusGui.ps1'; Add-Content $gs '# tampered'
$p = Start-Process $Exe -ArgumentList '--no-elevate' -PassThru; $p.WaitForExit(15000) | Out-Null
Check 'tampered script restored' (-not ((Get-Content $gs -Raw) -match '# tampered'))
$gui = WaitWindow { param($w) $w.Current.Name -eq "Alpheus - $env:COMPUTERNAME" } 30
if ($gui) { $gui.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close() }

"`n$(if ($fail) { "$fail FAILED" } else { 'ALL PASSED' })"
exit $fail
