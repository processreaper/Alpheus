# Alpheus

Disk reclamation and performance audit for Windows 10/11, in PowerShell 7.

Named for the river Heracles turned through the Augean stables: it washes out the muck and
leaves the livestock alone. Alpheus cleans caches and leftovers you can afford to lose, and
measures — but never touches — the things you can't.

**Read-only by default.** Nothing is deleted unless you pass `-Apply` (or press *Apply* in the
GUI after a confirmation dialog), or delete something yourself on the Disk usage tab (also after a
confirmation). `-WhatIf` previews exactly what would be cleaned, with sizes.

## What it does

- **Audit:** free space per volume, disk health / temperature / wear, TRIM, every cleanup target
  sized and tiered, largest files in your profile, CPU microcode (flags 13th/14th-gen Intel parts
  below the Vmin-shift fix), unexpected shutdowns / WHEA / bugchecks, pending reboot, startup
  items, third-party auto-start services, top RAM users, GPU memory per process.
- **Clean** (only with `-Apply`): the tiers below.
- **Disk usage tab** (GUI): a fast parallel scanner with a size-sorted tree, a cushion treemap,
  and extension / largest-file breakdowns — like WinDirStat or WizTree. You can delete from it
  (see below).

## Deleting from the Disk usage tab

Select one item, or several with **Ctrl+click** / **Shift+click** (also in the *Largest files*
list), then right-click → **Delete**, or press **Del**.

- **Del** moves the items to the **Recycle Bin**. Nothing is lost until you empty it, and no space is
  freed until then either. If Windows can't recycle something (too big for the bin), Windows itself
  asks before deleting it permanently.
- **Shift+Del** deletes **permanently**, after a second confirmation that defaults to *No*.
- Before anything moves, one confirmation lists every item and the total size.
- **Always refused**, even if selected: drive roots, anything inside Windows, the Recycle Bin and
  System Volume Information, top-level folders such as Program Files, ProgramData, Users, your
  profile, AppData, Desktop and Documents, every PROTECTED folder **and any folder that contains
  one**, the scanned folder itself, and the grouped "[N files under 1 MB]" entries. If your
  `alpheus.config.json` can't be read, delete is disabled entirely.
- Installed apps and Steam / GOG games get a warning: their own uninstaller is cleaner. Deleting a
  Steam game's folder leaves Steam thinking it's still installed.
- The tree, treemap and *Largest files* list update right away; the *Extensions* totals update on
  the next scan.
- Every delete is logged to `%LOCALAPPDATA%\Alpheus\deletions.log` (time, mode, result, size, path).

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

Copy `alpheus.config.example.json` to **`%LOCALAPPDATA%\Alpheus\alpheus.config.json`** (or next
to the scripts, if you run them directly) and list them. Paths must be full paths; `%VARIABLES%`
are expanded; `Breakdown: true` adds a per-subfolder size list to the report.

```json
{ "Protected": [ { "Name": "AI models", "Paths": ["D:\\Models"], "Breakdown": true } ] }
```

If the file exists but can't be read, or lists an empty or relative path, Alpheus **refuses to
run** (exit 2) rather than run with an unknown set of protections.

## Requirements

- Windows 10 or 11
- [PowerShell 7](https://aka.ms/powershell) (`pwsh`), which includes WPF for the GUI. If it is
  missing, `Alpheus.exe` tells you how to install it (`winget install --id Microsoft.PowerShell`).
- Administrator rights for the full audit and most cleanup categories (see below)

## Run it

### The easy way: Alpheus.exe

Download **`Alpheus.exe`** from the [latest release](https://github.com/processreaper/Alpheus/releases/latest),
put it anywhere (the desktop is fine) and double-click it. Accept the UAC prompt for the full audit,
or decline it to run with partial results.

- The `.exe` is a small launcher with the scripts inside. On each start it unpacks them to
  `%LOCALAPPDATA%\Alpheus\app\<version>` (repairing them if they were changed) and starts the GUI.
  It needs nothing installed besides PowerShell 7.
- **It is not code-signed yet**, so the first run shows *"Windows protected your PC"*. Click
  **More info → Run anyway**. If you'd rather not trust an unsigned `.exe`, use the scripts below:
  they are the same code, and you can read every line.

### The scripts

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

The Disk usage tab's delete also runs with the GUI's rights, so when elevated it can remove files
your normal account couldn't. The refusal list above applies either way.

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

`tests\Test-AlpheusDelete.ps1` tests Disk usage deletes against a throwaway `%TEMP%` folder: the
refusal rules, recycle and permanent deletes (both confirmations), mixed selections, warnings, the
*Largest files* list, the log, and that every folder in your config is refused. It cleans its own
items back out of the Recycle Bin.

`tests\Test-AlpheusExe.ps1` repeats the GUI end-to-end checks through `dist\Alpheus.exe --no-elevate` and also checks
the missing-PowerShell dialog (it pops up on screen), unpacking, old-version cleanup, the window
icon and repair of a tampered unpacked file.

## Building

```powershell
.\tools\New-AlpheusIcon.ps1                    # assets\alpheus.ico + alpheus-256.png (already committed)
.\tools\Build-AlpheusExe.ps1 -Version 0.2.0    # dist\Alpheus.exe
```

The launcher (`launcher\AlpheusLauncher.cs`) targets .NET Framework 4.8 and is compiled with the
C# compiler that ships with Windows, so no SDK is needed.

## Uninstall

Alpheus installs nothing system-wide: no registry entries, services, scheduled tasks or shortcuts.
Everything it writes lives in `%LOCALAPPDATA%\Alpheus` (the unpacked program, reports, the delete
log, window layout and your config).

```
Alpheus.exe --uninstall
```

removes the unpacked program and asks whether to remove your reports and settings too. Then delete
`Alpheus.exe`. If you used the scripts, delete their folder and, optionally, `%LOCALAPPDATA%\Alpheus`.

Changes Alpheus can make to your system happen only when you ask for them (*Apply*, or a delete on
the Disk usage tab), each behind a confirmation. Turning hibernation off (`powercfg /hibernate off`)
is undone with `powercfg /hibernate on`.

## Code signing policy

Release binaries are built from this repository by GitHub Actions
(`.github/workflows/release.yml`) on GitHub-hosted runners, never on a developer machine.

Alpheus has not yet been accepted for free code signing. Once it is, this section will read:
*Free code signing provided by [SignPath.io](https://about.signpath.io), certificate by
[SignPath Foundation](https://signpath.org).* Until then `Alpheus.exe` is unsigned.

Team roles:

- Committers and reviewers: [processreaper](https://github.com/processreaper)
- Approvers: [processreaper](https://github.com/processreaper)

Privacy: this program will not transfer any information to other networked systems unless
specifically requested by the user or the person installing or operating it. Its only network
actions: opening the PowerShell download page in your browser, if you choose that when PowerShell 7
is missing; and, if Ollama is installed, running `ollama list` to show your local models (which asks
your own Ollama server, normally on this PC). Reports and logs stay in `%LOCALAPPDATA%\Alpheus`.

## License

MIT — see `LICENSE`.
