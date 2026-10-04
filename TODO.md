# Known gaps

- **`-Deep` is not a drill-down.** It sizes each top-level folder separately and runs DISM
  analyze. A single-pass walk that drills into folders over 50 GB and reports `DEEP`-tier rows
  is planned; the GUI already sorts on a `DEEP` tier that nothing emits yet. Until then, use the
  Disk usage tab.
- **Mixed-DPI window restore.** The layout restore checks the saved position against monitors
  using the primary monitor's scale. With monitors at different scaling, a window saved on a
  scaled monitor may reopen at the default position. Use per-monitor DPI.
- **"Freed" for DevCaches overstates** when uv has hardlinked cache files into environments.
  Report the volume free-space delta alongside the per-category count.
- **DataGrid column drag-to-reorder** has been tested with simulated drag events and by hand for
  resizing, but reordering has not had a real-mouse pass.
- Lint with PSScriptAnalyzer before each release.
- Optional later: PowerShell Gallery (`Install-Script`), code signing.
