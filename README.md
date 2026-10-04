# Alpheus

Disk reclamation and performance audit for Windows 10/11, in PowerShell 7.

Named for the river Heracles turned through the Augean stables: it washes out the muck and
leaves the livestock alone. Alpheus cleans caches and leftovers you can afford to lose, and
measures — but never touches — the things you can't.

**Read-only by default.** Nothing is deleted unless you pass `-Apply` (or press *Apply* in the
GUI after a confirmation dialog). `-WhatIf` previews exactly what would be cleaned, with sizes.

## What it does

- **Audit:** free space per volume, disk health / temperature / wear, TRIM, every cleanup target
  sized and tiered, largest files in your profile, CPU microcode (flags 13th/14th-gen Intel parts
  below the Vmin-shift fix), unexpected shutdowns / WHEA / bugchecks, pending reboot, startup
  items, third-party auto-start services, top RAM users, GPU memory per process.
- **Clean** (only with `-Apply`): the tiers below.
- **Disk usage tab** (GUI): a fast parallel scanner with a size-sorted tree, a cushion treemap,
  and extension / largest-file breakdowns — like WinDirStat or WizTree. **It has no delete
  button, by design**: it shows you where the space is; you act in Explorer, deliberately.

## Tiers

| Tier | What | Cleaned when |
|---|---|---|
| **SAFE** | Temp (files older than 2 days), Windows Error Reporting queue, Delivery Optimization cache, Windows Update download cache, old NVIDIA driver packages | `-Apply` (default set) |
| **OPT-IN** | Crash dumps, dev caches (pip / npm / uv / yarn / NuGet), browser caches, Recycle Bin, component store (DISM), hibernation file | only when named in `-Include` |
| **PROTECTED** | Downloads, Ollama models, Hugging Face / torch caches, plus **your own folders** from `alpheus.config.json` | **never** — measured only |
| **INFO** | shader caches, pagefile, Windows.old | never — context only |

PROTECTED is enforced, not just labelled: cleanup skips any file under a protected path even if
it sits inside a cleanup target, and a category whose own folder is protected is skipped whole.

### Protect your own folders

Copy `alpheus.config.example.json` to `alpheus.config.json` (next to the scripts) and list
them. `%VARIABLES%` are expanded; `Breakdown: true` adds a per-subfolder size list to the report.

```json
{ "Protected": [ { "Name": "AI models", "Paths": ["D:\\Models"], "Breakdown": true } ] }
```

If the file exists but can't be read, Alpheus **refuses to run** (exit 2) rather than run with
an unknown set of protections.

## Requirements

- Windows 10 or 11
- [PowerShell 7](https://aka.ms/powershell) (`pwsh`), which includes WPF for the GUI
- Administrator rights for the full audit and most cleanup categories (see below)

## Run it

Download the release zip, extract it, then **unblock** the files (they came from the internet):

```powershell
Get-ChildItem .\Alpheus -Recurse | Unblock-File
```

GUI:

```powershell
pwsh -File .\Start-AlpheusGui.ps1
```

Engine:

```powershell
.\Invoke-Alpheus.ps1                                          # audit only, changes nothing
.\Invoke-Alpheus.ps1 -Apply -WhatIf                           # preview the SAFE set, with sizes
.\Invoke-Alpheus.ps1 -Apply                                   # clean the SAFE set
.\Invoke-Alpheus.ps1 -Apply -Include Safe,DevCaches -WhatIf   # preview SAFE + dev caches
```

Calling from outside PowerShell, use `-Command` (with `-File`, a comma list arrives as one
string): `pwsh -Command "& '.\Invoke-Alpheus.ps1' -Apply -Include Temp,DevCaches -WhatIf"`

Every run writes a transcript and a JSON report to `%LOCALAPPDATA%\Alpheus`.

## What runs as administrator

The GUI asks for elevation (UAC) when it starts; decline it and it runs with partial results.
Elevation is needed to read system folders, disk reliability counters, shadow-copy storage and
DISM, and to clean the system-wide categories. Under elevation, `-Apply` can:

- delete files inside the cleanup targets listed above (never anything under a PROTECTED path)
- run `Delete-DeliveryOptimizationCache`, `pip cache purge`, `npm cache clean --force`, `uv cache clean`
- stop `wuauserv` and `bits` briefly to clear the Windows Update cache (skipped if a reboot is pending)
- run `Clear-RecycleBin`, `dism /Online /Cleanup-Image /StartComponentCleanup`, `powercfg /hibernate off`

It never deletes the folders above themselves, never follows junctions, never touches
PROTECTED paths, and does nothing at all without `-Apply`.

## Things worth knowing

- **Preview first.** `-Apply -WhatIf` shows each category with its measured size.
- **Recycle Bin is permanent.** Look inside before including it.
- **Hibernation off also disables Fast Startup.**
- **"Freed" can overstate dev caches.** uv hardlinks packages from its cache into virtual
  environments; clearing the cache leaves those bytes in place. Compare free space before/after.
- **Crash dumps are evidence.** Alpheus won't delete them when recent crashes exist unless forced.
- **Disk usage sizes are logical sizes;** hardlinks count once per link (so WinSxS looks bigger
  than it is), junctions are not followed, and files under 1 MB are grouped per folder.
- The GUI remembers its window, splitter and column layout in `%LOCALAPPDATA%\Alpheus\layout.json`.
  Delete that file to reset it.

## Tests

`tests\Test-AlpheusGuiE2E.ps1` launches the GUI unelevated and drives it through UI Automation:
opens the Disk usage tab, scans `C:\`, checks the result, closes.

## License

MIT — see `LICENSE`.
