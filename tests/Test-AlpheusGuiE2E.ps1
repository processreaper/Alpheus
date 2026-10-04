# End-to-end: launch the real GUI file (non-elevated), drive it from OUTSIDE via UI Automation, read results.
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$A = [Windows.Automation.AutomationElement]; $C = [Windows.Automation.TreeScope]
$p = Start-Process 'C:\Program Files\PowerShell\7\pwsh.exe' -PassThru -RedirectStandardError "$env:TEMP\alpheus-e2e-err.txt" `
    -ArgumentList '-NoProfile -ExecutionPolicy Bypass -STA -File "C:\dev\Alpheus\Start-AlpheusGui.ps1" -NoElevate'
$win = $null
for ($i = 0; $i -lt 80 -and -not $win; $i++) {
    Start-Sleep -Milliseconds 250
    $cond = [Windows.Automation.AndCondition]::new(
        [Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty, $p.Id),
        [Windows.Automation.PropertyCondition]::new($A::NameProperty, "Alpheus - $env:COMPUTERNAME"))
    $win = $A::RootElement.FindFirst($C::Children, $cond)
}
if (-not $win) { "NO WINDOW (exited=$($p.HasExited))"; Get-Content "$env:TEMP\alpheus-e2e-err.txt"; return }
function ById($id) { $win.FindFirst($C::Descendants, [Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty, $id)) }
function Text($id) { $e = ById $id; if ($e) { $e.Current.Name } else { '<not found>' } }

$tab = $win.FindFirst($C::Descendants, [Windows.Automation.AndCondition]::new(
    [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, [Windows.Automation.ControlType]::TabItem),
    [Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Disk usage')))
$tab.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select(); Start-Sleep -Milliseconds 500
"lblScan before: $(Text 'lblScan')"
$btn = ById 'btnScan'
"btnScan enabled: $($btn.Current.IsEnabled)"
if ($btn.Current.IsEnabled) {
    $btn.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    for ($i = 0; $i -lt 120; $i++) { Start-Sleep -Milliseconds 500; $t = Text 'lblScan'; if ($t -match '^(Done|Cancelled|Scan failed|GUI error)') { break } }
    "lblScan after : $t"
    $hdr = $win.FindAll($C::Descendants, [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, [Windows.Automation.ControlType]::TreeItem))
    "tree items visible: $($hdr.Count)"
    "treemap label: $(Text 'lblTmRoot')"
}
$win.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close()
[void]$p.WaitForExit(15000); "exit code: $($p.ExitCode)"
"stderr: $((Get-Content "$env:TEMP\alpheus-e2e-err.txt" -Raw))"
