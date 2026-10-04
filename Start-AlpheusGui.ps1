#Requires -Version 7.0
<#
.SYNOPSIS
    Alpheus GUI - WPF front end for Invoke-Alpheus.ps1.

.DESCRIPTION
    Keep this file next to Invoke-Alpheus.ps1. The GUI never deletes anything itself;
    it builds the same command line you would type and runs the engine as a hidden
    child pwsh, streaming its output live. Results (targets, findings, volumes) are
    read back from the engine's JSON report.

    Buttons:
      Audit    - read-only run (no -Apply)
      Preview  - -Apply -WhatIf for the ticked categories; nothing changes
      Apply    - real cleanup for the ticked categories, after a confirmation dialog

    Disk usage tab (WizTree/WinDirStat-style, read-only):
      - parallel scan of a drive or folder by an embedded C# engine (no PowerShell loops on the hot path)
      - size-sorted tree with percent-of-parent bars
      - cushion treemap: hover for path/size, click to select, double-click to zoom in, Zoom out to go up
      - extension and largest-file breakdowns
      - right-click: Open in Explorer / Copy path / Zoom here / Rescan here
      Nothing on that tab deletes anything; use Explorer for that, on purpose.
      Sizes are logical file sizes; hardlinks count once per link (WinSxS overstates), and junctions are not followed.

    Self-elevates via UAC on launch (decline it to run unelevated with partial results).

.EXAMPLE
    pwsh -NoProfile -ExecutionPolicy Bypass -File .\Start-AlpheusGui.ps1
#>
param([switch]$NoElevate)

$ErrorActionPreference = 'Continue'
$Engine   = Join-Path $PSScriptRoot 'Invoke-Alpheus.ps1'
$PwshPath = (Get-Process -Id $PID).Path
$IsAdmin  = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ---------------------------------------------------------------- elevation / STA
if (-not $IsAdmin -and -not $NoElevate) {
    try {
        Start-Process $PwshPath -Verb RunAs -WindowStyle Hidden `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`" -NoElevate"
        exit
    } catch { }   # UAC declined - carry on unelevated
}
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Start-Process $PwshPath -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`" -NoElevate"
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing   # Forms: monitor list for layout restore

# Own taskbar identity: without it the window groups under pwsh.exe and shows the PowerShell icon.
# Must be set before the first window exists. Cosmetic, so any failure is ignored.
try {
    if (-not ('Alpheus.Shell' -as [type])) {
        Add-Type -Namespace Alpheus -Name Shell -MemberDefinition '[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string id);'
    }
    [void][Alpheus.Shell]::SetCurrentProcessExplicitAppUserModelID('processreaper.Alpheus')
} catch { Write-Verbose "AppUserModelID not set: $_" }

# ---------------------------------------------------------------- disk scan engine (C#, compiled once per launch)
$ScanSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Enumeration;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace Alpheus
{
    public sealed class Node
    {
        public string Name;
        public Node Parent;
        public long Size;
        public long FileCount;
        public long DirCount;
        public bool IsFile;
        public bool IsAggregate;
        public bool Denied;
        public DateTime Modified;
        public int Group;
        public List<Node> Children;

        public bool HasChildren { get { return Children != null && Children.Count > 0; } }
        public bool IsDirectory { get { return !IsFile; } }

        public string FullPath
        {
            get
            {
                if (IsAggregate) return Parent == null ? Name : Parent.FullPath;
                var parts = new List<string>();
                for (var n = this; n != null; n = n.Parent) parts.Add(n.Name);
                parts.Reverse();
                return Path.Combine(parts.ToArray());
            }
        }

        public override string ToString() { return Name; }
    }

    public static class Groups
    {
        public const int Other = 0, Aggregate = 10, Folder = 11;
        public static readonly string[] Names = {
            "Other", "AI models", "Video", "Images", "Audio", "Archives / disk images",
            "Executables / libraries", "Code / text", "Game data", "Databases", "Small files", "Folder" };
        public static readonly int[] Colors = {
            0x8A93A3, 0x9B6BFF, 0xE5534B, 0xE0B860, 0xE06CC0, 0x4C8DF6,
            0x57C46A, 0x3CC7C7, 0xF08A3C, 0x2FA889, 0x596070, 0x46506A };

        static readonly Dictionary<string, int> map = Build();

        static Dictionary<string, int> Build()
        {
            var d = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            Action<int, string> add = (g, list) => { foreach (var e in list.Split(' ')) d["." + e] = g; };
            add(1, "gguf safetensors ckpt pt pth bin onnx ggml h5 pb tflite npz npy mlmodel engine trt");
            add(2, "mkv mp4 m2ts avi mov webm ts wmv m4v mpg mpeg vob flv");
            add(3, "png jpg jpeg webp gif bmp tif tiff raw dng heic psd exr cr2 nef arw");
            add(4, "mp3 flac wav m4a aac ogg opus wma aiff");
            add(5, "zip 7z rar tar gz tgz xz zst bz2 iso img vhd vhdx vmdk qcow2 wim esd cab");
            add(6, "exe dll sys msi so pyd lib pdb node msix appx cat mui");
            add(7, "py js ts json txt md c h cpp cs ps1 psm1 yml yaml xml html css log csv ipynb toml ini cfg");
            add(8, "pak vpk bundle assets ucas utoc bsa ba2 big forge rpf wad arc pck ress");
            add(9, "db sqlite sqlite3 ldb mdf ndf edb parquet");
            return d;
        }

        public static int Of(string ext)
        {
            int g;
            return ext != null && map.TryGetValue(ext, out g) ? g : Other;
        }
    }

    public sealed class ExtStat
    {
        public string Ext;
        public int Group;
        public long Size;
        public long Count;
    }

    public sealed class Scanner
    {
        public long Files, Dirs, Bytes, DeniedCount;
        public volatile string Current = "";
        public Node Root;
        public Exception Error;
        public volatile bool Cancelled;
        public long FileNodeThreshold = 1L << 20;   // files >= 1 MiB get their own node; smaller ones are aggregated per folder
        public int ParallelDepth = 4;
        public readonly Stopwatch Clock = new Stopwatch();
        public readonly List<string> DeniedPaths = new List<string>();

        readonly Dictionary<string, ExtStat> exts = new Dictionary<string, ExtStat>(StringComparer.OrdinalIgnoreCase);
        readonly object gate = new object();
        CancellationTokenSource cts;
        Task task;

        static readonly EnumerationOptions Opts = new EnumerationOptions
        {
            RecurseSubdirectories = false,
            IgnoreInaccessible = false,      // we want to know which folders were denied
            AttributesToSkip = 0,            // include hidden + system
            ReturnSpecialDirectories = false
        };

        struct Entry
        {
            public string Name;
            public bool IsDir, IsLink;
            public long Length;
            public DateTime Mod;
        }

        public bool IsCompleted { get { return task != null && task.IsCompleted; } }

        public void Start(string path)
        {
            string full = Path.GetFullPath(path);
            Root = new Node { Name = full, Children = new List<Node>() };
            cts = new CancellationTokenSource();
            var ct = cts.Token;
            Clock.Restart();
            task = Task.Run(() =>
            {
                try { Scan(Root, full, 0, ct); }
                catch (OperationCanceledException) { Cancelled = true; }
                catch (AggregateException ae)
                {
                    if (ae.Flatten().InnerExceptions.All(e => e is OperationCanceledException)) Cancelled = true;
                    else Error = ae.Flatten().InnerExceptions.First();
                }
                catch (Exception e) { Error = e; }
                finally
                {
                    if (Cancelled) Rollup(Root);   // partial tree still gets usable totals
                    Clock.Stop();
                }
            });
        }

        public void Cancel() { if (cts != null) cts.Cancel(); }

        public bool Wait(int ms) { return task == null || task.Wait(ms); }

        void MarkDenied(Node dir, string path)
        {
            dir.Denied = true;
            Interlocked.Increment(ref DeniedCount);
            lock (gate) { if (DeniedPaths.Count < 200) DeniedPaths.Add(path); }
        }

        void Scan(Node dir, string path, int depth, CancellationToken ct)
        {
            ct.ThrowIfCancellationRequested();
            Current = path;
            var subdirs = new List<KeyValuePair<Node, string>>();
            var local = new Dictionary<string, long[]>(StringComparer.OrdinalIgnoreCase);
            long files = 0, bytes = 0, smallCount = 0, smallSize = 0;
            DateTime smallMod = DateTime.MinValue;

            try
            {
                var en = new FileSystemEnumerable<Entry>(path, (ref FileSystemEntry e) => new Entry
                {
                    Name = e.FileName.ToString(),
                    IsDir = e.IsDirectory,
                    IsLink = (e.Attributes & FileAttributes.ReparsePoint) != 0,
                    Length = e.IsDirectory ? 0 : e.Length,
                    Mod = e.LastWriteTimeUtc.UtcDateTime
                }, Opts);

                foreach (var x in en)
                {
                    if (x.IsDir)
                    {
                        if (x.IsLink) continue;   // never follow junctions / symlinks (no double counting, no loops)
                        var c = new Node { Name = x.Name, Parent = dir, Children = new List<Node>(), Modified = x.Mod };
                        dir.Children.Add(c);
                        subdirs.Add(new KeyValuePair<Node, string>(c, Path.Join(path, x.Name)));
                        continue;
                    }
                    files++;
                    bytes += x.Length;
                    string ext = Path.GetExtension(x.Name);
                    if (string.IsNullOrEmpty(ext)) ext = "(none)";
                    long[] acc;
                    if (!local.TryGetValue(ext, out acc)) { acc = new long[2]; local[ext] = acc; }
                    acc[0] += x.Length; acc[1]++;

                    if (x.Length >= FileNodeThreshold)
                        dir.Children.Add(new Node { Name = x.Name, Parent = dir, IsFile = true, Size = x.Length, FileCount = 1, Modified = x.Mod, Group = Groups.Of(ext) });
                    else
                    {
                        smallCount++; smallSize += x.Length;
                        if (x.Mod > smallMod) smallMod = x.Mod;
                    }
                }
            }
            catch (UnauthorizedAccessException) { MarkDenied(dir, path); }
            catch (IOException) { MarkDenied(dir, path); }

            if (smallCount > 0)
                dir.Children.Add(new Node
                {
                    Name = "[" + smallCount.ToString("N0") + " files under 1 MB]",
                    Parent = dir, IsFile = true, IsAggregate = true,
                    Size = smallSize, FileCount = smallCount, Modified = smallMod, Group = Groups.Aggregate
                });

            Interlocked.Add(ref Files, files);
            Interlocked.Add(ref Bytes, bytes);
            Interlocked.Increment(ref Dirs);
            if (local.Count > 0)
            {
                lock (gate)
                {
                    foreach (var kv in local)
                    {
                        string k = kv.Key.ToLowerInvariant();
                        ExtStat s;
                        if (!exts.TryGetValue(k, out s)) { s = new ExtStat { Ext = k, Group = k == "(none)" ? Groups.Other : Groups.Of(k) }; exts[k] = s; }
                        s.Size += kv.Value[0];
                        s.Count += kv.Value[1];
                    }
                }
            }

            if (depth < ParallelDepth && subdirs.Count > 1)
                Parallel.ForEach(subdirs, new ParallelOptions { CancellationToken = ct }, kv => Scan(kv.Key, kv.Value, depth + 1, ct));
            else
                foreach (var kv in subdirs) Scan(kv.Key, kv.Value, depth + 1, ct);

            Sum(dir);
        }

        static void Sum(Node dir)
        {
            long size = 0, fc = 0, dc = 0;
            foreach (var c in dir.Children)
            {
                size += c.Size;
                fc += c.FileCount;
                if (!c.IsFile) dc += 1 + c.DirCount;
            }
            dir.Size = size; dir.FileCount = fc; dir.DirCount = dc;
            dir.Children.Sort((a, b) => b.Size.CompareTo(a.Size));
        }

        static void Rollup(Node dir)
        {
            if (dir.Children == null) return;
            foreach (var c in dir.Children) if (!c.IsFile) Rollup(c);
            Sum(dir);
        }

        // Remove a deleted node from the tree and recompute every ancestor (size, counts, sort order).
        public static void Detach(Node n)
        {
            var p = n == null ? null : n.Parent;
            if (p == null || p.Children == null || !p.Children.Remove(n)) return;
            for (var a = p; a != null; a = a.Parent) Sum(a);
        }

        // True while n is still reachable from root (not inside a detached branch).
        public static bool IsAttached(Node n, Node root)
        {
            for (var c = n; c != null; c = c.Parent)
            {
                if (ReferenceEquals(c, root)) return true;
                if (c.Parent != null && !c.Parent.Children.Contains(c)) return false;
            }
            return false;
        }

        public List<ExtStat> Extensions()
        {
            lock (gate) return exts.Values.OrderByDescending(e => e.Size).ToList();
        }

        public List<Node> LargestFiles(int n)
        {
            var acc = new List<Node>();
            Collect(Root, acc);
            return acc.OrderByDescending(x => x.Size).Take(n).ToList();
        }

        static void Collect(Node d, List<Node> acc)
        {
            if (d == null || d.Children == null) return;
            foreach (var c in d.Children)
            {
                if (c.IsFile) { if (!c.IsAggregate) acc.Add(c); }
                else Collect(c, acc);
            }
        }
    }

    // Acheron: carries deleted items away. One SHFileOperation for the whole batch, so Windows shows a
    // single progress window. Recycle: FOF_ALLOWUNDO + FOF_WANTNUKEWARNING, so anything Windows cannot
    // recycle (too big for the bin) asks before it is destroyed instead of vanishing silently.
    // Alpheus has already confirmed, hence FOF_NOCONFIRMATION (no per-item "are you sure").
    public static class Acheron
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct SHFILEOPSTRUCT
        {
            public IntPtr hwnd; public uint wFunc;
            [MarshalAs(UnmanagedType.LPWStr)] public string pFrom;
            [MarshalAs(UnmanagedType.LPWStr)] public string pTo;
            public ushort fFlags; public bool fAnyOperationsAborted; public IntPtr hNameMappings;
            [MarshalAs(UnmanagedType.LPWStr)] public string lpszProgressTitle;
        }
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SHFileOperation(ref SHFILEOPSTRUCT op);

        const uint FO_DELETE = 3;
        const ushort FOF_NOCONFIRMATION = 0x0010, FOF_ALLOWUNDO = 0x0040, FOF_WANTNUKEWARNING = 0x4000;

        // Returns 0 on success; Aborted is true if the user cancelled in a Windows dialog.
        public static int Delete(IntPtr owner, IList<string> paths, bool permanent, out bool aborted)
        {
            var op = new SHFILEOPSTRUCT
            {
                hwnd = owner, wFunc = FO_DELETE,
                pFrom = string.Join("\0", paths) + "\0\0",
                fFlags = (ushort)(FOF_NOCONFIRMATION | (permanent ? 0 : FOF_ALLOWUNDO | FOF_WANTNUKEWARNING))
            };
            int rc = SHFileOperation(ref op);
            aborted = op.fAnyOperationsAborted;
            return rc;
        }
    }

    public sealed class TmItem
    {
        public Node Node;
        public int X, Y, W, H, Depth;
    }

    // Squarified treemap (Bruls/Huizing/van Wijk) with cushion shading (van Wijk/van de Wetering),
    // rendered straight into a BGRA32 buffer so the UI only has to wrap it in a bitmap.
    public sealed class Treemap
    {
        public readonly int Width, Height;
        public readonly int[] Pixels;
        public readonly List<TmItem> Items = new List<TmItem>();
        readonly Dictionary<Node, TmItem> index = new Dictionary<Node, TmItem>();

        const double H0 = 0.38, F = 0.91, Ia = 0.22, Is = 0.78, MinSplit = 3.0;
        static readonly double Lx, Ly, Lz;

        static Treemap()
        {
            double lx = -1, ly = -1, lz = 10, len = Math.Sqrt(lx * lx + ly * ly + lz * lz);
            Lx = lx / len; Ly = ly / len; Lz = lz / len;
        }

        struct R { public double X, Y, W, H; public R(double x, double y, double w, double h) { X = x; Y = y; W = w; H = h; } }

        public Treemap(Node root, int width, int height, int background = 0x0C0E12)
        {
            Width = Math.Max(1, width);
            Height = Math.Max(1, height);
            Pixels = new int[Width * Height];
            int bg = unchecked((int)0xFF000000) | background;
            for (int i = 0; i < Pixels.Length; i++) Pixels[i] = bg;
            if (root != null && root.Size > 0)
                Draw(root, new R(0, 0, Width, Height), new double[4], H0, 0);
        }

        void Draw(Node n, R r, double[] parent, double h, int depth)
        {
            int x0 = (int)Math.Round(r.X), y0 = (int)Math.Round(r.Y);
            int x1 = Math.Min(Width, (int)Math.Round(r.X + r.W)), y1 = Math.Min(Height, (int)Math.Round(r.Y + r.H));
            if (x1 <= x0 || y1 <= y0) return;   // sub-pixel: leave the parent's colour showing

            var s = (double[])parent.Clone();
            if (r.W > 1e-9) { s[1] += 4 * h * (2 * r.X + r.W) / r.W; s[0] -= 4 * h / r.W; }
            if (r.H > 1e-9) { s[3] += 4 * h * (2 * r.Y + r.H) / r.H; s[2] -= 4 * h / r.H; }

            var it = new TmItem { Node = n, X = x0, Y = y0, W = x1 - x0, H = y1 - y0, Depth = depth };
            Items.Add(it);
            index[n] = it;

            bool leaf = n.IsFile || !n.HasChildren || r.W < MinSplit || r.H < MinSplit;
            int color = n.IsFile ? Groups.Colors[n.Group] : Groups.Colors[Groups.Folder];
            Cushion(x0, y0, x1, y1, s, color);
            if (leaf) return;

            var kids = new List<Node>();
            foreach (var c in n.Children) if (c.Size > 0) kids.Add(c);   // already sorted descending
            foreach (var kv in Squarify(kids, r))
                Draw(kv.Key, kv.Value, s, h * F, depth + 1);
            if (depth >= 1 && depth <= 2 && it.W > 6 && it.H > 6) Outline(it, depth == 1 ? 2 : 1);
        }

        void Outline(TmItem it, int t)
        {
            int c = unchecked((int)0xFF0C0E12);
            for (int k = 0; k < t; k++)
            {
                int xa = it.X + k, xb = it.X + it.W - 1 - k, ya = it.Y + k, yb = it.Y + it.H - 1 - k;
                if (xb <= xa || yb <= ya) return;
                for (int x = xa; x <= xb; x++) { Pixels[ya * Width + x] = c; Pixels[yb * Width + x] = c; }
                for (int y = ya; y <= yb; y++) { Pixels[y * Width + xa] = c; Pixels[y * Width + xb] = c; }
            }
        }

        static List<KeyValuePair<Node, R>> Squarify(List<Node> kids, R r)
        {
            var result = new List<KeyValuePair<Node, R>>(kids.Count);
            double total = 0;
            foreach (var k in kids) total += k.Size;
            if (total <= 0 || r.W <= 0 || r.H <= 0) return result;
            double scale = r.W * r.H / total;
            int i = 0;
            var rem = r;
            while (i < kids.Count)
            {
                double side = Math.Min(rem.W, rem.H);
                if (side <= 0) break;
                int start = i;
                double rowSum = 0, worst = double.MaxValue, rmax = kids[start].Size * scale;
                while (i < kids.Count)
                {
                    double a = kids[i].Size * scale, sum = rowSum + a;
                    double w = Math.Max(side * side * rmax / (sum * sum), sum * sum / (side * side * a));
                    if (i > start && w > worst) break;
                    worst = w; rowSum = sum; i++;
                }
                double thick = rowSum / side;
                if (rem.W >= rem.H)
                {   // column on the left, items stacked down
                    double y = rem.Y;
                    for (int k = start; k < i; k++) { double hh = kids[k].Size * scale / thick; result.Add(new KeyValuePair<Node, R>(kids[k], new R(rem.X, y, thick, hh))); y += hh; }
                    rem = new R(rem.X + thick, rem.Y, Math.Max(0, rem.W - thick), rem.H);
                }
                else
                {   // row along the top, items left to right
                    double x = rem.X;
                    for (int k = start; k < i; k++) { double ww = kids[k].Size * scale / thick; result.Add(new KeyValuePair<Node, R>(kids[k], new R(x, rem.Y, ww, thick))); x += ww; }
                    rem = new R(rem.X, rem.Y + thick, rem.W, Math.Max(0, rem.H - thick));
                }
            }
            return result;
        }

        void Cushion(int x0, int y0, int x1, int y1, double[] s, int rgb)
        {
            int cr = (rgb >> 16) & 255, cg = (rgb >> 8) & 255, cb = rgb & 255;
            for (int y = y0; y < y1; y++)
            {
                double ny = -(2 * s[2] * (y + 0.5) + s[3]);
                int row = y * Width;
                for (int x = x0; x < x1; x++)
                {
                    double nx = -(2 * s[0] * (x + 0.5) + s[1]);
                    double cos = (nx * Lx + ny * Ly + Lz) / Math.Sqrt(nx * nx + ny * ny + 1.0);
                    if (cos < 0) cos = 0;
                    double f = Ia + Is * cos;
                    if (f > 1) f = 1;
                    Pixels[row + x] = unchecked((int)0xFF000000) | ((int)(cr * f) << 16) | ((int)(cg * f) << 8) | (int)(cb * f);
                }
            }
        }

        public TmItem HitTest(int x, int y)
        {
            for (int i = Items.Count - 1; i >= 0; i--)
            {
                var it = Items[i];
                if (x >= it.X && x < it.X + it.W && y >= it.Y && y < it.Y + it.H) return it;
            }
            return null;
        }

        // Rect for n, or for its nearest drawn ancestor; null if n is outside this map.
        public TmItem Find(Node n)
        {
            for (var p = n; p != null; p = p.Parent)
            {
                TmItem it;
                if (index.TryGetValue(p, out it)) return it;
            }
            return null;
        }
    }
}
'@
$script:ScanLoadError = $null
if (-not ('Alpheus.Scanner' -as [type])) {
    try { Add-Type -TypeDefinition $ScanSource -Language CSharp -ErrorAction Stop }
    catch { $script:ScanLoadError = $_.Exception.Message }
}

if (-not (Test-Path -LiteralPath $Engine)) {
    [Windows.MessageBox]::Show("Invoke-Alpheus.ps1 not found next to this script:`n$Engine", 'Alpheus', 'OK', 'Error') | Out-Null
    exit 1
}

$SafeCats = 'Temp', 'WER', 'DeliveryOpt', 'WUCache', 'NvidiaInstallers'
$OptCats  = 'CrashDumps', 'DevCaches', 'BrowserCache', 'RecycleBin', 'ComponentStore', 'Hibernation'
$CatHelp = @{
    Temp             = 'User + Windows temp (age-gated)'
    WER              = 'Windows error-report queue/archive'
    DeliveryOpt      = 'Delivery Optimization peer cache'
    WUCache          = 'Windows Update download cache'
    NvidiaInstallers = 'Old NVIDIA driver packages'
    CrashDumps       = 'Minidumps / MEMORY.DMP (evidence!)'
    DevCaches        = 'pip / npm / uv / yarn / NuGet caches'
    BrowserCache     = 'Chrome / Edge / Brave caches (close browsers)'
    RecycleBin       = 'Empty Recycle Bin (permanent)'
    ComponentStore   = 'DISM WinSxS cleanup (slow)'
    Hibernation      = 'hiberfil.sys off (kills Fast Startup)'
}

function New-CatXaml([string[]]$cats, [bool]$checked) {
    ($cats | ForEach-Object {
        "<CheckBox Name=`"cb_$_`" IsChecked=`"$($checked.ToString())`" Margin=`"0,3`" ToolTip=`"$($CatHelp[$_])`">" +
        "<StackPanel><TextBlock Text=`"$_`"/><TextBlock Text=`"$($CatHelp[$_])`" FontSize=`"11`" Foreground=`"#8A93A3`"/></StackPanel></CheckBox>"
    }) -join "`n"
}

# ---------------------------------------------------------------- XAML
[xml]$Xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Alpheus - $env:COMPUTERNAME" Width="1480" Height="920" MinWidth="960" MinHeight="650"
        Background="#111318" Foreground="#E6E6E6" FontFamily="Segoe UI" FontSize="13"
        WindowStartupLocation="CenterScreen">
  <Window.Resources>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E6E6E6"/>
      <Setter Property="VerticalContentAlignment" Value="Top"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="#E6E6E6"/>
      <Setter Property="Background" Value="#262A33"/>
      <Setter Property="BorderBrush" Value="#3A3F4B"/>
      <Setter Property="Padding" Value="12,7"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#323845"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="#E6E6E6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border Name="b" Padding="16,7" Background="#111318" BorderThickness="0,0,0,2" BorderBrush="Transparent">
              <ContentPresenter ContentSource="Header"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#5FB3B3"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TreeViewItem">
      <Style.Resources>
        <!-- headers set their own light foregrounds, so the stock near-white selection made the selected row unreadable -->
        <SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}" Color="#1F3A3A"/>
        <SolidColorBrush x:Key="{x:Static SystemColors.InactiveSelectionHighlightBrushKey}" Color="#262A33"/>
      </Style.Resources>
      <Setter Property="Foreground" Value="#E6E6E6"/>
      <Setter Property="Padding" Value="1,2"/>
    </Style>
    <Style TargetType="DataGrid">
      <Setter Property="AutoGenerateColumns" Value="True"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="CanUserSortColumns" Value="True"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="GridLinesVisibility" Value="None"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Background" Value="#111318"/>
      <Setter Property="RowBackground" Value="#111318"/>
      <Setter Property="AlternatingRowBackground" Value="#161920"/>
      <Setter Property="Foreground" Value="#E6E6E6"/>
      <Setter Property="CanUserResizeColumns" Value="True"/>
      <Setter Property="CanUserReorderColumns" Value="True"/>
    </Style>
    <Style TargetType="GridSplitter">
      <Setter Property="Background" Value="#111318"/>
      <Setter Property="Focusable" Value="False"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#2A3A3A"/></Trigger>
        <Trigger Property="IsDragging" Value="True"><Setter Property="Background" Value="#5FB3B3"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="#1A1D24"/>
      <Setter Property="Foreground" Value="#B8C0CC"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="BorderBrush" Value="#2A2E37"/>
      <Setter Property="BorderThickness" Value="0,0,1,1"/>
    </Style>
  </Window.Resources>

  <DockPanel Margin="14">
    <!-- header -->
    <DockPanel DockPanel.Dock="Top" Margin="0,0,0,12">
      <TextBlock Name="lblAdmin" DockPanel.Dock="Right" VerticalAlignment="Center" FontSize="12"/>
      <StackPanel>
        <TextBlock Text="Alpheus" FontSize="22" FontWeight="SemiBold"/>
        <TextBlock Text="Disk reclamation + performance audit for $env:COMPUTERNAME. Audit is read-only; nothing is deleted without Apply."
                   Foreground="#8A93A3" FontSize="12"/>
      </StackPanel>
    </DockPanel>

    <!-- status bar -->
    <Border DockPanel.Dock="Bottom" Background="#1A1D24" CornerRadius="4" Padding="10,6" Margin="0,10,0,0">
      <DockPanel>
        <TextBlock Name="lblElapsed" DockPanel.Dock="Right" Foreground="#8A93A3"/>
        <TextBlock Name="lblStatus" Text="Ready."/>
      </DockPanel>
    </Border>

    <!-- body: options | splitter | results. Named definitions are persisted to layout.json (Mnemosyne). -->
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Name="colLeft" Width="300" MinWidth="230" MaxWidth="560"/>
        <ColumnDefinition Width="12"/>
        <ColumnDefinition Name="colMain" Width="*" MinWidth="660"/>
      </Grid.ColumnDefinitions>
    <!-- left: options -->
    <Border Grid.Column="0" Background="#1A1D24" CornerRadius="6" Padding="14">
      <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel>
          <TextBlock Text="SAFE" FontWeight="SemiBold" Foreground="#7FD18B"/>
          $(New-CatXaml $SafeCats $true)
          <TextBlock Text="OPT-IN" FontWeight="SemiBold" Foreground="#E0B860" Margin="0,12,0,0"/>
          $(New-CatXaml $OptCats $false)

          <TextBlock Text="OPTIONS" FontWeight="SemiBold" Foreground="#8A93A3" Margin="0,14,0,4"/>
          <DockPanel Margin="0,2">
            <TextBox Name="txtAge" DockPanel.Dock="Right" Width="48" Text="2" Background="#262A33" Foreground="#E6E6E6"
                     BorderBrush="#3A3F4B" HorizontalContentAlignment="Center"/>
            <TextBlock Text="Temp age gate (days)" VerticalAlignment="Center"/>
          </DockPanel>
          <CheckBox Name="cbDeep" Margin="0,6,0,0"><TextBlock TextWrapping="Wrap" Text="Deep scan (whole drives + DISM analyze; slow)"/></CheckBox>
          <CheckBox Name="cbResetBase" Margin="0,4,0,0"><TextBlock TextWrapping="Wrap" Text="ResetBase with ComponentStore"/></CheckBox>

          <Separator Margin="0,14" Background="#2A2E37"/>
          <Button Name="btnAudit"   Content="Audit (read-only)" Background="#1F3A3A" BorderBrush="#5FB3B3"/>
          <Button Name="btnPreview" Content="Preview cleanup (WhatIf)"/>
          <Button Name="btnApply"   Content="Apply cleanup" Background="#3A2626" BorderBrush="#B35F5F"/>
          <Button Name="btnStop"    Content="Stop" IsEnabled="False"/>
          <Button Name="btnFolder"  Content="Open log folder"/>
        </StackPanel>
      </ScrollViewer>
    </Border>
    <GridSplitter Name="splLeft" Grid.Column="1" Width="12" HorizontalAlignment="Stretch" ResizeBehavior="PreviousAndNext"/>

    <!-- right: results -->
    <TabControl Name="tabs" Grid.Column="2" Background="#1A1D24" BorderBrush="#2A2E37" Padding="0">
      <TabItem Header="Log">
        <TextBox Name="txtLog" IsReadOnly="True" FontFamily="Cascadia Mono, Consolas" FontSize="12"
                 Background="#0C0E12" Foreground="#D7DCE3" BorderThickness="0" Padding="10"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
      </TabItem>
      <TabItem Header="Targets">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Name="rowTotals" Height="40" MinHeight="30" MaxHeight="240"/>
            <RowDefinition Height="6"/>
            <RowDefinition Name="rowTargets" Height="*" MinHeight="100"/>
          </Grid.RowDefinitions>
          <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <TextBlock Name="lblTotals" Margin="10,8" Foreground="#B8C0CC" TextWrapping="Wrap"/>
          </ScrollViewer>
          <GridSplitter Name="splTotals" Grid.Row="1" Height="6" HorizontalAlignment="Stretch" ResizeBehavior="PreviousAndNext"/>
          <DataGrid Name="gridTargets" Grid.Row="2"/>
        </Grid>
      </TabItem>
      <TabItem Header="Findings">
        <TextBox Name="txtFindings" IsReadOnly="True" TextWrapping="Wrap" FontSize="13"
                 Background="#0C0E12" Foreground="#E6E6E6" BorderThickness="0" Padding="12"
                 VerticalScrollBarVisibility="Auto"/>
      </TabItem>
      <TabItem Header="Disk usage">
        <DockPanel Background="#111318">
          <DockPanel DockPanel.Dock="Top" Margin="10,10,10,6">
            <TextBlock Text="Scan" VerticalAlignment="Center" Margin="0,0,8,0" Foreground="#8A93A3"/>
            <Button Name="btnScan" DockPanel.Dock="Right" Content="Scan" Width="90" Margin="6,0,0,0" Padding="10,5" Background="#1F3A3A" BorderBrush="#5FB3B3"/>
            <Button Name="btnScanCancel" DockPanel.Dock="Right" Content="Cancel" Width="80" Margin="6,0,0,0" Padding="10,5" IsEnabled="False"/>
            <Button Name="btnBrowse" DockPanel.Dock="Right" Content="Browse..." Width="90" Margin="6,0,0,0" Padding="10,5"/>
            <TextBox Name="txtRoot" Text="C:\" Background="#262A33" Foreground="#E6E6E6" BorderBrush="#3A3F4B" Padding="6,4" VerticalContentAlignment="Center"/>
          </DockPanel>
          <TextBlock Name="lblScan" DockPanel.Dock="Top" Margin="10,0,10,8" Foreground="#B8C0CC" TextTrimming="CharacterEllipsis"
                     Text="Pick a drive or folder and press Scan. Ctrl/Shift-click to select several; Del sends to the Recycle Bin, Shift+Del deletes permanently."/>
          <Grid Margin="10,0,10,10">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Name="colTree" Width="2*" MinWidth="300"/>
              <ColumnDefinition Width="6"/>
              <ColumnDefinition Name="colRight" Width="3*" MinWidth="320"/>
            </Grid.ColumnDefinitions>
            <DockPanel Grid.Column="0">
              <!-- tree column header: a row-less DataGrid, so resize grips and drag-to-reorder are WPF's own.
                   Tree rows follow its column widths and order (Update-TreeColumns). Scrolls horizontally with the tree. -->
              <Border DockPanel.Dock="Top" Background="#1A1D24" BorderBrush="#2A2E37" BorderThickness="1,1,1,0">
                <ScrollViewer Name="tvHeaderScroll" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Disabled">
                  <DataGrid Name="dgTree" HorizontalAlignment="Left" AutoGenerateColumns="False" CanUserSortColumns="False"
                            CanUserAddRows="False" Background="#1A1D24" MinHeight="0" FrozenColumnCount="1"
                            HorizontalScrollBarVisibility="Disabled" VerticalScrollBarVisibility="Disabled">
                    <!-- Name is pinned first (frozen + not reorderable): the first column absorbs the tree indent, which
                         only a trimmable name can afford; Size / Share / % reorder freely behind it -->
                    <DataGrid.Columns>
                      <DataGridTextColumn Header="Name"  Width="260" MinWidth="80" CanUserReorder="False"/>
                      <DataGridTextColumn Header="Size"  Width="90"  MinWidth="56"/>
                      <DataGridTextColumn Header="Share" Width="72"  MinWidth="30"/>
                      <DataGridTextColumn Header="%"     Width="62"  MinWidth="44"/>
                    </DataGrid.Columns>
                  </DataGrid>
                </ScrollViewer>
              </Border>
              <TreeView Name="tvDisk" Background="#0C0E12" BorderBrush="#2A2E37" Foreground="#E6E6E6"/>
            </DockPanel>
            <GridSplitter Name="splTree" Grid.Column="1" Width="6" HorizontalAlignment="Stretch" ResizeBehavior="PreviousAndNext"/>
            <Grid Grid.Column="2">
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Name="rowUpper" Height="3*" MinHeight="220"/>
                <RowDefinition Height="6"/>
                <RowDefinition Name="rowGrids" Height="2*" MinHeight="120"/>
              </Grid.RowDefinitions>
              <DockPanel Grid.Row="0" Margin="0,0,0,4">
                <Button Name="btnZoomOut" DockPanel.Dock="Right" Content="Zoom out" Padding="10,3" Margin="6,0,0,0" IsEnabled="False"/>
                <TextBlock Name="lblTmRoot" Foreground="#8A93A3" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
              </DockPanel>
              <!-- treemap | splitter | hover + legend strip, nested so the grids splitter below resizes the treemap, not the strip -->
              <Grid Grid.Row="1">
                <Grid.RowDefinitions>
                  <RowDefinition Name="rowTm" Height="*" MinHeight="140"/>
                  <RowDefinition Height="6"/>
                  <RowDefinition Name="rowLegend" Height="64" MinHeight="40"/>
                </Grid.RowDefinitions>
                <Border Grid.Row="0" Background="#0C0E12" BorderBrush="#2A2E37" BorderThickness="1" ClipToBounds="True">
                  <Grid Name="tmGrid">
                    <Image Name="imgTreemap" HorizontalAlignment="Left" VerticalAlignment="Top" Stretch="Fill" Cursor="Hand"/>
                    <Canvas IsHitTestVisible="False">
                      <Rectangle Name="tmHighlight" Stroke="White" StrokeThickness="2" Visibility="Collapsed"/>
                    </Canvas>
                  </Grid>
                </Border>
                <GridSplitter Name="splLegend" Grid.Row="1" Height="6" HorizontalAlignment="Stretch" ResizeBehavior="PreviousAndNext"/>
                <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                  <StackPanel>
                    <TextBlock Name="lblTm" Foreground="#E6E6E6" TextTrimming="CharacterEllipsis" Text=" "/>
                    <WrapPanel Name="pnlLegend" Margin="0,4,0,0"/>
                  </StackPanel>
                </ScrollViewer>
              </Grid>
              <GridSplitter Name="splGrids" Grid.Row="2" Height="6" HorizontalAlignment="Stretch" ResizeBehavior="PreviousAndNext"/>
              <TabControl Grid.Row="3" Background="#1A1D24" BorderBrush="#2A2E37" Padding="0">
                <TabItem Header="Extensions"><DataGrid Name="gridExt"/></TabItem>
                <TabItem Header="Largest files"><DataGrid Name="gridBig"/></TabItem>
              </TabControl>
            </Grid>
          </Grid>
        </DockPanel>
      </TabItem>
    </TabControl>
    </Grid>
  </DockPanel>
</Window>
"@

$Win = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($Xaml))
# Window + taskbar icon: next to the script (Alpheus.exe unpacks it there) or in assets\ (repo layout).
foreach ($ico in (Join-Path $PSScriptRoot 'alpheus.ico'), (Join-Path $PSScriptRoot 'assets\alpheus.ico')) {
    if (Test-Path -LiteralPath $ico) {
        try { $Win.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$ico) } catch { Write-Verbose "icon not loaded: $_" }
        break
    }
}
$ui = @{}
foreach ($n in 'lblAdmin', 'lblStatus', 'lblElapsed', 'lblTotals', 'txtAge', 'cbDeep', 'cbResetBase', 'btnAudit', 'btnPreview',
               'btnApply', 'btnStop', 'btnFolder', 'tabs', 'txtLog', 'gridTargets', 'txtFindings',
               'btnScan', 'btnScanCancel', 'btnBrowse', 'txtRoot', 'lblScan', 'tvDisk', 'btnZoomOut', 'lblTmRoot',
               'tmGrid', 'imgTreemap', 'tmHighlight', 'lblTm', 'pnlLegend', 'gridExt', 'gridBig',
               'tvHeaderScroll', 'dgTree',
               'splLeft', 'splTree', 'splLegend', 'splGrids', 'splTotals') {
    $ui[$n] = $Win.FindName($n)
}
foreach ($c in $SafeCats + $OptCats) { $ui["cb_$c"] = $Win.FindName("cb_$c") }

$ui.lblAdmin.Text = if ($IsAdmin) { 'ELEVATED' } else { 'NOT ELEVATED - partial results' }
$ui.lblAdmin.Foreground = if ($IsAdmin) { '#7FD18B' } else { '#E0B860' }

# ---------------------------------------------------------------- run state
$script:Proc = $null; $script:OutTask = $null; $script:ErrTask = $null
$script:OutEof = $false; $script:ErrEof = $false
$script:Clock = [Diagnostics.Stopwatch]::new()
$script:Mode = ''
$Timer = [Windows.Threading.DispatcherTimer]::new()
$Timer.Interval = [TimeSpan]::FromMilliseconds(200)

function Get-SelectedCats { ($SafeCats + $OptCats) | Where-Object { $ui["cb_$_"].IsChecked } }

function Set-Busy([bool]$busy) {
    foreach ($b in 'btnAudit', 'btnPreview', 'btnApply') { $ui[$b].IsEnabled = -not $busy }
    $ui.btnStop.IsEnabled = $busy
}

function Read-Pending([ref]$task, [IO.StreamReader]$reader, [ref]$eof, [Text.StringBuilder]$sb) {
    # Poll .NET ReadLineAsync tasks from the UI thread - no PowerShell code ever runs off-thread.
    for ($i = 0; $i -lt 400 -and -not $eof.Value; $i++) {
        if ($null -eq $task.Value) { $task.Value = $reader.ReadLineAsync() }
        if (-not $task.Value.IsCompleted) { return }
        $line = $task.Value.Result; $task.Value = $null
        if ($null -eq $line) { $eof.Value = $true; return }
        [void]$sb.AppendLine($line)
    }
}

function ConvertFrom-StdErr([string]$text) {
    # pwsh serialises error/warning records as CLIXML when stderr is redirected; decode them to plain lines.
    foreach ($line in ($text -split "`r?`n")) {
        if (-not $line -or $line -match '^#< CLIXML') { continue }
        if ($line -match '^<Objs') {
            foreach ($m in [regex]::Matches($line, '<S S="(Error|Warning)">(.*?)</S>')) {
                $msg = [Net.WebUtility]::HtmlDecode(($m.Groups[2].Value -replace '_x000D_', '' -replace '_x000A_', ' ')).Trim()
                if ($msg) { "[$($m.Groups[1].Value.ToLower())] $msg`r`n" }
            }
            continue
        }
        "[stderr] $line`r`n"
    }
}

function Start-AlpheusRun([ValidateSet('Audit', 'Preview', 'Apply')][string]$Mode) {
    $age = 0
    if (-not [int]::TryParse($ui.txtAge.Text, [ref]$age) -or $age -lt 0 -or $age -gt 365) {
        [Windows.MessageBox]::Show('Temp age gate must be a whole number 0-365.', 'Alpheus', 'OK', 'Warning') | Out-Null; return
    }
    $cats = @(Get-SelectedCats)
    $force = $false
    $q = { param($s) "'" + ($s -replace "'", "''") + "'" }
    $parts = [Collections.Generic.List[string]]::new()
    $parts.Add('& ' + (& $q $Engine))
    $parts.Add("-TempAgeDays $age")
    if ($ui.cbDeep.IsChecked) { $parts.Add('-Deep') }

    if ($Mode -ne 'Audit') {
        if (-not $cats.Count) { [Windows.MessageBox]::Show('Tick at least one category.', 'Alpheus', 'OK', 'Information') | Out-Null; return }
        $parts.Add('-Apply')
        $parts.Add('-Include ' + (($cats | ForEach-Object { & $q $_ }) -join ','))
        if ($ui.cbResetBase.IsChecked -and 'ComponentStore' -in $cats) { $parts.Add('-ResetBase') }
    }
    if ($Mode -eq 'Preview') { $parts.Add('-WhatIf') }
    if ($Mode -eq 'Apply') {
        $warn = "Permanently clean:`n`n  " + ($cats -join "`n  ")
        if ('Hibernation' -in $cats) { $warn += "`n`nHibernation off also disables Fast Startup." }
        if ('WUCache' -in $cats)     { $warn += "`nWUCache stops wuauserv/bits briefly; do not hit Stop mid-run." }
        $warn += "`n`nRun Preview first if you have not. Continue?"
        if ([Windows.MessageBox]::Show($warn, 'Alpheus - confirm apply', 'YesNo', 'Warning') -ne 'Yes') { return }
        if ('CrashDumps' -in $cats) {
            $r = [Windows.MessageBox]::Show("Delete crash dumps even if the audit found recent bugchecks / WHEA events?`n`nNo = keep them when crashes exist (recommended until you've read them).",
                'Alpheus - crash dumps', 'YesNo', 'Warning')
            $force = ($r -eq 'Yes')
        }
        if ($force) { $parts.Add('-Force') }
    }

    $cmd = "[Console]::OutputEncoding = [Text.Encoding]::UTF8; `$PSStyle.OutputRendering = 'PlainText'; `$ProgressPreference = 'SilentlyContinue'; " + ($parts -join ' ')
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))

    $psi = [Diagnostics.ProcessStartInfo]::new($PwshPath)
    foreach ($a in '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $psi.Environment['NO_COLOR'] = '1'

    $ui.txtLog.Clear()
    $ui.txtLog.AppendText("> $($parts -join ' ')`r`n`r`n")
    $ui.tabs.SelectedIndex = 0
    $script:OutTask = $null; $script:ErrTask = $null; $script:OutEof = $false; $script:ErrEof = $false
    $script:Mode = $Mode
    try { $script:Proc = [Diagnostics.Process]::Start($psi) }
    catch { [Windows.MessageBox]::Show("Could not start pwsh:`n$_", 'Alpheus', 'OK', 'Error') | Out-Null; return }
    Set-Busy $true
    $ui.lblStatus.Text = "$Mode running..."
    $script:Clock.Restart()
    $Timer.Start()
}

function Complete-AlpheusRun {
    $Timer.Stop(); $script:Clock.Stop()
    $code = $script:Proc.ExitCode
    $script:Proc.Dispose(); $script:Proc = $null
    Set-Busy $false
    $ui.lblStatus.Text = "$($script:Mode) finished (exit $code)."

    $m = [regex]::Match($ui.txtLog.Text, 'JSON:\s*(.+?\.json)')
    if (-not $m.Success -or -not (Test-Path -LiteralPath $m.Groups[1].Value)) {
        $ui.lblStatus.Text += ' No JSON report found - see Log.'; return
    }
    $r = Get-Content -LiteralPath $m.Groups[1].Value -Raw | ConvertFrom-Json

    $rows = @($r.Targets | ForEach-Object {
        [pscustomobject]@{ Tier = $_.Tier; Category = $_.Category; GB = [math]::Round($_.SizeBytes / 1GB, 2); Path = $_.Path }
    } | Sort-Object @{ e = { @{ SAFE = 0; 'OPT-IN' = 1; PROTECTED = 2; INFO = 3; DEEP = 4 }[$_.Tier] } }, @{ e = 'GB'; Descending = $true })
    Save-GridColumns 'gridTargets'   # keep this session's widths across the column regeneration
    $ui.gridTargets.ItemsSource = $rows
    $sum = { param($t) [math]::Round((($rows | Where-Object Tier -eq $t | Measure-Object GB -Sum).Sum), 2) }
    $ui.lblTotals.Text = "SAFE reclaimable: $(& $sum 'SAFE') GB     OPT-IN: $(& $sum 'OPT-IN') GB (WinSxS overstates)     PROTECTED: $(& $sum 'PROTECTED') GB"

    $sb = [Text.StringBuilder]::new()
    [void]$sb.AppendLine("Microcode: $($r.Microcode)    Elevated: $($r.Admin)    Mode: $($r.Mode)")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('VOLUMES')
    foreach ($v in @($r.Volumes)) { [void]$sb.AppendLine(('  {0}  {1,-14} {2,8:N1} GB free of {3,8:N1} GB' -f $v.Drive, $v.Label, $v.FreeGB, $v.SizeGB)) }
    if ($r.Freed -and @($r.Freed.PSObject.Properties).Count) {
        [void]$sb.AppendLine(); [void]$sb.AppendLine('FREED')
        foreach ($p in $r.Freed.PSObject.Properties) { [void]$sb.AppendLine(('  {0,-18} {1:N2} GB' -f $p.Name, ($p.Value / 1GB))) }
    }
    [void]$sb.AppendLine(); [void]$sb.AppendLine('FINDINGS')
    $f = @($r.Findings)
    if ($f.Count) { $f | ForEach-Object { [void]$sb.AppendLine("  - $_"); [void]$sb.AppendLine() } } else { [void]$sb.AppendLine('  nothing flagged') }
    $ui.txtFindings.Text = $sb.ToString()
    $ui.tabs.SelectedIndex = if ($f.Count) { 2 } else { 1 }
}

$Timer.Add_Tick({
    try {
        if (-not $script:Proc) { $Timer.Stop(); return }
        $sb = [Text.StringBuilder]::new()
        Read-Pending ([ref]$script:OutTask) $script:Proc.StandardOutput ([ref]$script:OutEof) $sb
        $err = [Text.StringBuilder]::new()
        Read-Pending ([ref]$script:ErrTask) $script:Proc.StandardError ([ref]$script:ErrEof) $err
        if ($err.Length) { [void]$sb.Append((ConvertFrom-StdErr $err.ToString()) -join '') }
        if ($sb.Length) { $ui.txtLog.AppendText(($sb.ToString() -replace "\x1b\[[0-9;?]*[A-Za-z]", '')); $ui.txtLog.ScrollToEnd() }
        $ui.lblElapsed.Text = '{0:mm\:ss}' -f $script:Clock.Elapsed
        if ($script:OutEof -and $script:ErrEof -and $script:Proc.HasExited) { Complete-AlpheusRun }
    } catch {
        $Timer.Stop(); Set-Busy $false
        $ui.lblStatus.Text = "GUI error: $_"
    }
})


# ================================================================ Disk usage tab
$script:Scanner = $null; $script:Tm = $null; $script:TmRoot = $null; $script:TmScale = 1.0; $script:Selected = $null
$ScanTimer = [Windows.Threading.DispatcherTimer]::new(); $ScanTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$RenderTimer = [Windows.Threading.DispatcherTimer]::new(); $RenderTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$MaxTreeChildren = 400

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1TB) { return '{0:N2} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return '{0:N0} B' -f $Bytes
}

$BrushCache = @{}
function Get-Brush([int]$rgb) {
    if (-not $BrushCache.ContainsKey($rgb)) {
        $b = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(($rgb -shr 16) -band 255, ($rgb -shr 8) -band 255, $rgb -band 255))
        $b.Freeze(); $BrushCache[$rgb] = $b
    }
    $BrushCache[$rgb]
}
$TealBrush = Get-Brush 0x5FB3B3
$DimBrush  = Get-Brush 0x8A93A3
$TextBrush = Get-Brush 0xE6E6E6
$WarnBrush = Get-Brush 0xE0B860

function Get-GroupName([int]$g) { [Alpheus.Groups]::Names[$g] }

function Get-DirOf($n) { if ($null -eq $n) { return $null }; if ($n.IsFile) { return $n.Parent }; return $n }

function Get-NodeLabel($n) {
    if ($null -eq $n) { return ' ' }
    $parts = @($n.FullPath, (Format-Size $n.Size))
    if ($n.IsAggregate)  { $parts += "$($n.FileCount.ToString('N0')) small files (aggregated)" }
    elseif ($n.IsFile)   { $parts += (Get-GroupName $n.Group) }
    else                 { $parts += "$($n.FileCount.ToString('N0')) files, $($n.DirCount.ToString('N0')) folders" }
    if ($n.Modified -gt [datetime]::MinValue) { $parts += 'modified ' + $n.Modified.ToLocalTime().ToString('yyyy-MM-dd') }
    if ($n.Denied) { $parts += 'ACCESS DENIED (partial)' }
    $parts -join '   |   '
}

$TreeIndent = 19   # px per tree level: the stock TreeViewItem expander column (MinWidth 19); verified by measurement

function Get-NodeDepth($n) { $d = 0; for ($p = $n.Parent; $null -ne $p; $p = $p.Parent) { $d++ }; $d }

$script:TreeColLayout = @()   # [{Key; Width}] in display order, read from dgTree

function Get-TreeColLayout {
    @($ui.dgTree.Columns | Sort-Object DisplayIndex | ForEach-Object {
        $w = if ($_.ActualWidth -gt 0) { $_.ActualWidth } else { $_.Width.DisplayValue }
        if (-not ($w -gt 0)) { $w = $_.MinWidth }
        [pscustomobject]@{ Key = "$($_.Header)"; Width = [double]$w } })
}

function Set-RowColumns($g) {
    # Place a row's tagged cells in header display order and size them like the header. The first displayed
    # column is narrowed by the row's indent (Tag), so every later column lines up at any depth.
    $L = $script:TreeColLayout
    if ($L.Count -ne 4 -or $g.ColumnDefinitions.Count -ne 4) { return }
    for ($i = 0; $i -lt 4; $i++) {
        $w = $L[$i].Width; if ($i -eq 0) { $w -= [double]$g.Tag }
        $g.ColumnDefinitions[$i].Width = [Windows.GridLength]::new([math]::Max(12, $w))
    }
    foreach ($c in $g.Children) {
        for ($i = 0; $i -lt 4; $i++) { if ($L[$i].Key -eq $c.Tag) { [Windows.Controls.Grid]::SetColumn($c, $i); break } }
    }
}

function Update-TreeColumns {
    $script:TreeColLayout = Get-TreeColLayout
    $stack = [Collections.Generic.Stack[object]]::new()
    foreach ($it in $ui.tvDisk.Items) { $stack.Push($it) }
    while ($stack.Count) {
        $it = $stack.Pop()
        if ($it -isnot [Windows.Controls.TreeViewItem]) { continue }
        if ($it.Header -is [Windows.Controls.Grid]) { Set-RowColumns $it.Header }
        foreach ($c in $it.Items) { $stack.Push($c) }
    }
}

function New-NodeHeader($n, [double]$parentSize) {
    # Cells tagged Name | Size | Share | %; Set-RowColumns puts them where the header says.
    $pct = if ($parentSize -gt 0) { [math]::Max(0.0, [math]::Min(1.0, $n.Size / $parentSize)) } else { 0.0 }
    $g = [Windows.Controls.Grid]::new()
    $g.Tag = [double]($TreeIndent * (Get-NodeDepth $n))
    for ($i = 0; $i -lt 4; $i++) { $g.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new()) }

    $t3 = [Windows.Controls.TextBlock]::new()
    $t3.TextTrimming = 'CharacterEllipsis'; $t3.Margin = [Windows.Thickness]::new(0, 0, 10, 0)
    $name = [Windows.Documents.Run]::new($n.Name)
    if ($n.IsAggregate) { $name.Foreground = $DimBrush; $name.FontStyle = [Windows.FontStyles]::Italic }
    elseif ($n.Denied)  { $name.Foreground = $WarnBrush }
    else                { $name.Foreground = $TextBrush }
    if (-not $n.IsFile) { $name.FontWeight = [Windows.FontWeights]::SemiBold }
    $t3.Inlines.Add($name)
    if (-not $n.IsFile) {
        $meta = [Windows.Documents.Run]::new("   $($n.FileCount.ToString('N0')) files")
        $meta.Foreground = $DimBrush; $meta.FontSize = 11
        $t3.Inlines.Add($meta)
    }
    if ($n.Denied) {
        $d = [Windows.Documents.Run]::new('   access denied'); $d.Foreground = $WarnBrush; $d.FontSize = 11
        $t3.Inlines.Add($d)
    }
    $t3.ToolTip = $n.Name; $t3.Tag = 'Name'

    $t1 = [Windows.Controls.TextBlock]::new()
    $t1.Text = Format-Size $n.Size; $t1.TextAlignment = 'Right'; $t1.Margin = [Windows.Thickness]::new(0, 0, 10, 0); $t1.Foreground = $TextBrush
    $t1.Tag = 'Size'

    # bar stretches with its column: two star columns split pct : (1 - pct)
    $track = [Windows.Controls.Border]::new()
    $track.Height = 8; $track.CornerRadius = [Windows.CornerRadius]::new(2); $track.Background = Get-Brush 0x262A33
    $track.VerticalAlignment = 'Center'; $track.Margin = [Windows.Thickness]::new(0, 0, 10, 0)
    $bg = [Windows.Controls.Grid]::new()
    foreach ($v in $pct, (1.0 - $pct)) {
        $cd = [Windows.Controls.ColumnDefinition]::new(); $cd.Width = [Windows.GridLength]::new($v, 'Star'); $bg.ColumnDefinitions.Add($cd)
    }
    $fill = [Windows.Controls.Border]::new()
    $fill.CornerRadius = [Windows.CornerRadius]::new(2)
    $fill.Background = if ($n.IsFile) { Get-Brush ([Alpheus.Groups]::Colors[$n.Group]) } else { $TealBrush }
    [void]$bg.Children.Add($fill)
    $track.Child = $bg
    $track.Tag = 'Share'

    $t2 = [Windows.Controls.TextBlock]::new()
    $t2.Text = '{0:N1}%' -f (100 * $pct); $t2.Foreground = $DimBrush; $t2.TextAlignment = 'Right'; $t2.Margin = [Windows.Thickness]::new(0, 0, 10, 0)
    $t2.Tag = '%'

    foreach ($c in $t3, $t1, $track, $t2) { [void]$g.Children.Add($c) }
    Set-RowColumns $g
    $g
}

function Sync-TreeHeaderOffset {
    # Line the header row up with the root row's header (TreeView border + padding + expander column).
    $top = if ($ui.tvDisk.Items.Count) { $ui.tvDisk.Items[0] } else { $null }
    if ($top -isnot [Windows.Controls.TreeViewItem] -or $top.Header -isnot [Windows.UIElement]) { return }
    try {
        $ui.tvDisk.UpdateLayout()
        $x = $top.Header.TranslatePoint([Windows.Point]::new(0, 0), $ui.tvHeaderScroll).X + $ui.tvHeaderScroll.HorizontalOffset
        if ($x -ge 0 -and $x -lt 200) { $ui.dgTree.Margin = [Windows.Thickness]::new($x, 0, 24, 0) }
    } catch { }
}

function New-NodeItem($n, [double]$parentSize) {
    $ti = [Windows.Controls.TreeViewItem]::new()
    $ti.Header = New-NodeHeader $n $parentSize
    $ti.Tag = $n
    if ($n.HasChildren) { [void]$ti.Items.Add('...') }
    $ti
}

function Expand-NodeItem($ti) {
    if ($ti.Items.Count -ne 1 -or $ti.Items[0] -isnot [string]) { return }
    $ti.Items.Clear()
    $n = $ti.Tag
    $kids = $n.Children
    $take = [math]::Min($kids.Count, $MaxTreeChildren)
    for ($i = 0; $i -lt $take; $i++) { [void]$ti.Items.Add((New-NodeItem $kids[$i] $n.Size)) }
    if ($kids.Count -gt $take) {
        $rest = 0L; for ($i = $take; $i -lt $kids.Count; $i++) { $rest += $kids[$i].Size }
        $more = [Windows.Controls.TreeViewItem]::new()
        $more.Header = "... $($kids.Count - $take) smaller items, $(Format-Size $rest) (see treemap)"
        $more.Foreground = $DimBrush
        [void]$ti.Items.Add($more)
    }
}

function Select-InTree($node) {
    $chain = [Collections.Generic.List[object]]::new()
    for ($n = $node; $null -ne $n; $n = $n.Parent) { $chain.Insert(0, $n) }
    $items = $ui.tvDisk.Items; $last = $null
    foreach ($n in $chain) {
        $found = $null
        foreach ($it in $items) {
            if ($it -is [Windows.Controls.TreeViewItem] -and [object]::ReferenceEquals($it.Tag, $n)) { $found = $it; break }
        }
        if (-not $found) { break }      # beyond the per-folder display cap: stop at the deepest visible ancestor
        $last = $found
        if (-not [object]::ReferenceEquals($n, $node)) { Expand-NodeItem $found; $found.IsExpanded = $true }
        $items = $found.Items
    }
    if ($last) { $last.IsSelected = $true; $ui.tvDisk.UpdateLayout(); $last.BringIntoView() }
}

function Show-Highlight {
    $n = $script:Selected
    $it = if ($script:Tm -and $null -ne $n) { $script:Tm.Find($n) } else { $null }
    if (-not $it) { $ui.tmHighlight.Visibility = 'Collapsed'; return }
    $sc = $script:TmScale
    [Windows.Controls.Canvas]::SetLeft($ui.tmHighlight, $it.X / $sc)
    [Windows.Controls.Canvas]::SetTop($ui.tmHighlight, $it.Y / $sc)
    $ui.tmHighlight.Width  = [math]::Max(3, $it.W / $sc)
    $ui.tmHighlight.Height = [math]::Max(3, $it.H / $sc)
    $ui.tmHighlight.Visibility = 'Visible'
}

function Update-Treemap {
    if (-not $script:TmRoot) { return }
    $w = [math]::Floor($ui.tmGrid.ActualWidth); $h = [math]::Floor($ui.tmGrid.ActualHeight)
    if ($w -lt 20 -or $h -lt 20) { return }
    $sc = [Windows.Media.VisualTreeHelper]::GetDpi($ui.tmGrid).DpiScaleX
    $pw = [int][math]::Round($w * $sc); $ph = [int][math]::Round($h * $sc)
    $tm = [Alpheus.Treemap]::new($script:TmRoot, $pw, $ph, 0x0C0E12)
    $bmp = [Windows.Media.Imaging.BitmapSource]::Create($pw, $ph, 96 * $sc, 96 * $sc, [Windows.Media.PixelFormats]::Bgra32, $null, $tm.Pixels, $pw * 4)
    $bmp.Freeze()
    $ui.imgTreemap.Source = $bmp; $ui.imgTreemap.Width = $w; $ui.imgTreemap.Height = $h
    $script:Tm = $tm; $script:TmScale = $sc
    Show-Highlight
}

function Set-TreemapRoot($n) {
    if ($null -eq $n -or $n.IsFile) { return }
    $script:TmRoot = $n
    $ui.btnZoomOut.IsEnabled = ($null -ne $n.Parent)
    $ui.lblTmRoot.Text = "Treemap: $($n.FullPath)   ($(Format-Size $n.Size))   - double-click to zoom in"
    Update-Treemap
}

function Get-TmHit($e) {
    if (-not $script:Tm) { return $null }
    $p = $e.GetPosition($ui.imgTreemap)
    $script:Tm.HitTest([int][math]::Floor($p.X * $script:TmScale), [int][math]::Floor($p.Y * $script:TmScale))
}

function Set-DiskSelection($n) {
    if ($null -eq $n) { return }
    Select-InTree $n
    $script:Selected = $n          # after Select-InTree, which may only reach an ancestor
    $ui.lblTm.Text = Get-NodeLabel $n
    Show-Highlight
}

function Open-InExplorer($n) {
    if ($null -eq $n) { return }
    $p = $n.FullPath
    if ($n.IsFile -and -not $n.IsAggregate) { Start-Process explorer.exe -ArgumentList "/select,`"$p`"" }
    else { Start-Process explorer.exe -ArgumentList "`"$p`"" }
}

function Set-BigRows($s) {
    $ui.gridBig.ItemsSource = @($s.LargestFiles(1000) | ForEach-Object {
        [pscustomobject]@{ GB = [math]::Round($_.Size / 1GB, 2); Modified = $_.Modified.ToLocalTime().ToString('yyyy-MM-dd')
                           Type = Get-GroupName $_.Group; Path = $_.FullPath; Node = $_ }
    })
}

function Clear-DiskView {
    Clear-Mark
    $ui.tvDisk.Items.Clear()
    Save-GridColumns 'gridExt'; Save-GridColumns 'gridBig'
    $ui.gridExt.ItemsSource = $null; $ui.gridBig.ItemsSource = $null
    $ui.imgTreemap.Source = $null; $ui.tmHighlight.Visibility = 'Collapsed'
    $ui.lblTm.Text = ' '; $ui.lblTmRoot.Text = ''; $ui.btnZoomOut.IsEnabled = $false
    $script:Tm = $null; $script:TmRoot = $null; $script:Selected = $null
}

function Start-DiskScan([string]$path) {
    if ($script:ScanLoadError) { return }
    if ($script:Scanner -and -not $script:Scanner.IsCompleted) { return }
    $path = $path.Trim().Trim('"')
    if ($path -match '^[A-Za-z]:$') { $path += '\' }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        [Windows.MessageBox]::Show("Not a folder:`n$path", 'Alpheus', 'OK', 'Warning') | Out-Null; return
    }
    Clear-DiskView
    $script:Scanner = $null
    [GC]::Collect()
    $script:Scanner = [Alpheus.Scanner]::new()
    $script:Scanner.Start($path)
    $ui.btnScan.IsEnabled = $false; $ui.btnScanCancel.IsEnabled = $true
    $ui.lblScan.ToolTip = $null
    $ScanTimer.Start()
}

function Complete-DiskScan {
    $s = $script:Scanner
    $ui.btnScan.IsEnabled = $true; $ui.btnScanCancel.IsEnabled = $false
    if ($s.Error) { $ui.lblScan.Text = "Scan failed: $($s.Error.Message)"; return }
    $root = $s.Root
    $state = if ($s.Cancelled) { 'Cancelled - partial results' } else { 'Done' }
    $msg = '{0}: {1:N0} files, {2:N0} folders, {3} in {4:mm\:ss}' -f $state, $s.Files, $s.Dirs, (Format-Size $root.Size), $s.Clock.Elapsed
    if ($s.DeniedCount -gt 0) {
        $msg += "   |   $($s.DeniedCount) folders unreadable (hover for list)"
        $ui.lblScan.ToolTip = (@($s.DeniedPaths) | Select-Object -First 30) -join "`n"
    }
    if (-not $s.Cancelled -and [IO.Path]::GetPathRoot($root.Name) -eq $root.Name) {
        try {
            $di = [IO.DriveInfo]::new($root.Name)
            $gap = ($di.TotalSize - $di.TotalFreeSpace) - $root.Size
            if ($gap -gt 1GB)      { $msg += "   |   $(Format-Size $gap) used but not visible to the scan (restore points / System Volume Information, NTFS metadata)" }
            elseif ($gap -lt -1GB) { $msg += "   |   scan exceeds used space by $(Format-Size (-$gap)): hardlinks counted once per link" }
        } catch { }
    }
    $ui.lblScan.Text = $msg

    $top = New-NodeItem $root $root.Size
    [void]$ui.tvDisk.Items.Add($top)
    Expand-NodeItem $top; $top.IsExpanded = $true
    Sync-TreeHeaderOffset

    $total = [math]::Max([long]1, $root.Size)   # literal 1 alone binds Max(int,int) and throws past 2 GB
    $ui.gridExt.ItemsSource = @($s.Extensions() | Select-Object -First 400 | ForEach-Object {
        [pscustomobject]@{ Extension = $_.Ext; Type = Get-GroupName $_.Group; GB = [math]::Round($_.Size / 1GB, 2)
                           Percent = [math]::Round(100 * $_.Size / $total, 2); Files = $_.Count }
    })
    Set-BigRows $s

    $script:Selected = $root
    Set-TreemapRoot $root
}

$ScanTimer.Add_Tick({
    try {
        $s = $script:Scanner
        if (-not $s) { $ScanTimer.Stop(); return }
        $cur = $s.Current
        $ui.lblScan.Text = 'Scanning...  {0:N0} files   {1:N0} folders   {2}   {3:mm\:ss}   {4}' -f $s.Files, $s.Dirs, (Format-Size $s.Bytes), $s.Clock.Elapsed, $cur
        if ($s.IsCompleted) { $ScanTimer.Stop(); Complete-DiskScan }
    } catch {
        $ScanTimer.Stop(); $ui.btnScan.IsEnabled = $true; $ui.btnScanCancel.IsEnabled = $false
        $ui.lblScan.Text = "GUI error: $_"
    }
})
$RenderTimer.Add_Tick({ $RenderTimer.Stop(); try { Update-Treemap } catch { $ui.lblTm.Text = "Treemap error: $_" } })

# legend
foreach ($g in 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 10, 11) {
    $sp = [Windows.Controls.StackPanel]::new(); $sp.Orientation = 'Horizontal'; $sp.Margin = [Windows.Thickness]::new(0, 0, 12, 2)
    $sw = [Windows.Controls.Border]::new(); $sw.Width = 10; $sw.Height = 10; $sw.CornerRadius = [Windows.CornerRadius]::new(2); $sw.Margin = [Windows.Thickness]::new(0, 0, 5, 0)
    $sw.VerticalAlignment = 'Center'
    if ($script:ScanLoadError) { $sw.Background = $DimBrush } else { $sw.Background = Get-Brush ([Alpheus.Groups]::Colors[$g]) }
    $tb = [Windows.Controls.TextBlock]::new(); $tb.FontSize = 11; $tb.Foreground = $DimBrush
    $tb.Text = if ($script:ScanLoadError) { '' } else { Get-GroupName $g }
    [void]$sp.Children.Add($sw); [void]$sp.Children.Add($tb)
    [void]$ui.pnlLegend.Children.Add($sp)
}

# ================================================================ Acheron: delete from the Disk usage tab
# Added 2026-10-04 at the owner's request (the tab was originally read-only by design). Guardrails:
#   - Delete sends to the Recycle Bin; Shift+Delete is permanent after a second, default-No confirmation.
#   - One confirmation lists every item and the total before anything moves.
#   - Refused outright: drive roots, Windows / Recycle Bin / System Volume Information, top-level system
#     and profile folders, PROTECTED folders (built-ins + alpheus.config.json) and anything CONTAINING one,
#     the scan root, and the "[N files under 1 MB]" groups. An unreadable config disables delete entirely.
#   - Installed apps and Steam games get a warning: their own uninstaller is cleaner.
#   - Every outcome is appended to %LOCALAPPDATA%\Alpheus\deletions.log.
$script:Marked = [Collections.Generic.HashSet[object]]::new()   # TreeViewItems marked with Ctrl/Shift-click
$script:Anchor = $null
$MarkBrush = Get-Brush 0x24405A
$DeleteLog = Join-Path $env:LOCALAPPDATA 'Alpheus\deletions.log'

# Every Acheron dialog goes through these two, so tests can answer them and read their exact text.
function Show-DeleteConfirm([string]$text, [string]$title, [string]$icon) {
    [Windows.MessageBox]::Show($Win, $text, $title, 'YesNo', $icon, 'No') -eq 'Yes'
}
function Show-DeleteInfo([string]$text, [string]$icon = 'Information') {
    [Windows.MessageBox]::Show($Win, $text, 'Alpheus', 'OK', $icon) | Out-Null
}

function Format-Root([string]$p) { try { [IO.Path]::GetFullPath($p).TrimEnd('\') + '\' } catch { $null } }

function Initialize-DeleteGuard {
    # Same PROTECTED set as the engine: built-ins plus alpheus.config.json (next to the script, then
    # %LOCALAPPDATA%\Alpheus). Fail closed: if the config cannot be read, delete is disabled.
    $script:DeleteBlocked = $null
    $ollama = if ($env:OLLAMA_MODELS) { $env:OLLAMA_MODELS } else { Join-Path $env:USERPROFILE '.ollama\models' }
    $roots = [Collections.Generic.List[string]]::new()
    foreach ($b in (Join-Path $env:USERPROFILE 'Downloads'), $ollama, (Join-Path $env:USERPROFILE '.cache\huggingface'),
                   (Join-Path $env:USERPROFILE '.cache\torch'), $PSScriptRoot, (Join-Path $env:LOCALAPPDATA 'Alpheus')) {
        $r = Format-Root $b; if ($r) { $roots.Add($r) }
    }
    $cfgPath = @((Join-Path $PSScriptRoot 'alpheus.config.json'), (Join-Path $env:LOCALAPPDATA 'Alpheus\alpheus.config.json')) |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if ($cfgPath) {
        try {
            $cfg = Get-Content -LiteralPath $cfgPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            foreach ($e in @($cfg['Protected'])) {
                if ($e -isnot [hashtable] -or -not $e['Paths']) { throw 'each Protected entry needs Name and Paths' }
                foreach ($raw in @($e['Paths'])) {
                    $x = [Environment]::ExpandEnvironmentVariables([string]$raw)
                    if ([string]::IsNullOrWhiteSpace([string]$raw) -or ([string]$raw).Contains([char]0) -or -not [IO.Path]::IsPathFullyQualified($x)) { throw "bad path '$raw'" }
                    $roots.Add((Format-Root $x))
                }
            }
        } catch { $script:DeleteBlocked = "Delete is disabled: $cfgPath could not be read ($($_.Exception.Message)). Fix the file so Alpheus knows what is PROTECTED." }
    }
    $script:ProtectedRoots = @($roots)
    $script:SystemExact = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, (Join-Path $env:SystemDrive 'Users'),
        $env:USERPROFILE, $env:APPDATA, $env:LOCALAPPDATA, (Join-Path $env:USERPROFILE 'AppData'),
        [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'), [Environment]::GetFolderPath('MyPictures'),
        [Environment]::GetFolderPath('MyMusic'), [Environment]::GetFolderPath('MyVideos')) |
        Where-Object { $_ } | ForEach-Object { Format-Root $_ } | Where-Object { $_ }
    $script:SystemTree = @($env:SystemRoot) | ForEach-Object { Format-Root $_ }
}

function Get-RefuseReason([string]$path) {
    $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
    $p = $full + '\'
    if ($p -ieq ([IO.Path]::GetPathRoot($full).TrimEnd('\') + '\')) { return 'drive root' }
    if ($p -match '(?i)\\(\$Recycle\.Bin|System Volume Information)\\') { return 'Recycle Bin / system volume data' }
    if ([IO.Path]::GetFileName($full) -in 'pagefile.sys', 'hiberfil.sys', 'swapfile.sys') { return 'Windows system file' }
    foreach ($x in $script:SystemTree) { if ($p.StartsWith($x, [StringComparison]::OrdinalIgnoreCase)) { return 'inside Windows' } }
    foreach ($x in $script:SystemExact) { if ($p -ieq $x) { return 'top-level system or profile folder' } }
    foreach ($r in $script:ProtectedRoots) {
        if ($p.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)) { return 'PROTECTED' }
        if ($r.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) { return "contains PROTECTED folder $($r.TrimEnd('\'))" }
    }
    $null
}

function Get-DeleteWarning([string]$path) {
    if ($path -match '(?i)\\steamapps\\common\\[^\\]+$') { return 'Steam game: uninstalling in Steam is cleaner (deleting the folder leaves Steam thinking it is installed)' }
    if ($path -match '(?i)\\GOG Galaxy\\Games\\[^\\]+$') { return 'GOG game: uninstalling in GOG Galaxy is cleaner' }
    foreach ($pf in $env:ProgramFiles, ${env:ProgramFiles(x86)}) {
        if ($pf -and $path -match ('^(?i)' + [regex]::Escape($pf) + '\\[^\\]+$')) { return 'installed app: Settings > Apps > Uninstall is cleaner (registry, services, shortcuts)' }
    }
    $null
}

function Set-Mark($ti, [bool]$on) {
    if ($ti -isnot [Windows.Controls.TreeViewItem] -or $null -eq $ti.Tag) { return }
    if ($on) { [void]$script:Marked.Add($ti) } else { [void]$script:Marked.Remove($ti) }
    if ($ti.Header -is [Windows.Controls.Grid]) { $ti.Header.Background = $(if ($on) { $MarkBrush } else { $null }) }
}
function Clear-Mark { foreach ($ti in @($script:Marked)) { Set-Mark $ti $false }; $script:Marked.Clear() }

function Get-VisibleItem {
    # Tree items in on-screen order (expanded branches only), for Shift-click ranges.
    $out = [Collections.Generic.List[object]]::new()
    $walk = { param($items) foreach ($it in $items) { if ($it -is [Windows.Controls.TreeViewItem] -and $null -ne $it.Tag) { $out.Add($it); if ($it.IsExpanded) { & $walk $it.Items } } } }
    & $walk $ui.tvDisk.Items
    , $out
}

function Get-DeleteTarget([string]$from) {
    $nodes = switch ($from) {
        'tree'  { if ($script:Marked.Count) { @($script:Marked | ForEach-Object { $_.Tag }) } else { @($script:Selected) } }
        'grid'  { @($ui.gridBig.SelectedItems | ForEach-Object { $_.Node }) }
        default { @($script:Selected) }
    }
    $set = [Collections.Generic.HashSet[object]]::new()
    foreach ($n in $nodes) { if ($null -ne $n) { [void]$set.Add($n) } }
    # a selected item inside another selected folder goes with its parent
    @($set | Where-Object { $n = $_; $inside = $false; for ($a = $n.Parent; $null -ne $a; $a = $a.Parent) { if ($set.Contains($a)) { $inside = $true; break } }; -not $inside })
}

function Invoke-DiskDelete([string]$from, [bool]$permanent) {
    if ($script:DeleteBlocked) { Show-DeleteInfo $script:DeleteBlocked 'Warning'; return }
    if (-not $script:Scanner -or -not $script:Scanner.IsCompleted) { return }
    $ok = [Collections.Generic.List[object]]::new(); $refused = [Collections.Generic.List[string]]::new(); $warn = [Collections.Generic.List[string]]::new()
    foreach ($n in (Get-DeleteTarget $from)) {
        $why = if ($n.IsAggregate) { 'a group of small files - open the folder in Explorer to pick them' }
               elseif ($null -eq $n.Parent) { 'the scan root - select items inside it' }
               else { Get-RefuseReason $n.FullPath }
        if ($why) { $refused.Add("  $($n.FullPath)   ($why)"); continue }
        $ok.Add($n)
        $w = Get-DeleteWarning $n.FullPath; if ($w) { $warn.Add("  $($n.Name): $w") }
    }
    if (-not $ok.Count) {
        if ($refused.Count) { Show-DeleteInfo "Nothing can be deleted:`n`n$($refused -join "`n")" }
        return
    }
    $total = 0L; foreach ($n in $ok) { $total += $n.Size }
    $list = @($ok | Select-Object -First 12 | ForEach-Object { '  {0,10}   {1}' -f (Format-Size $_.Size), $_.FullPath })
    if ($ok.Count -gt 12) { $list += "  ... and $($ok.Count - 12) more" }
    $verb = if ($permanent) { 'PERMANENTLY DELETE' } else { 'Move to the Recycle Bin' }
    $msg = "$verb $($ok.Count) item(s), $(Format-Size $total):`n`n$($list -join "`n")"
    if ($warn.Count) { $msg += "`n`nWorth knowing:`n$($warn -join "`n")" }
    if ($refused.Count) { $msg += "`n`nWill NOT be touched:`n$($refused -join "`n")" }
    $msg += if ($permanent) { "`n`nThis cannot be undone." } else { "`n`nRecoverable from the Recycle Bin. Space is freed when you empty it." }
    $icon = if ($permanent) { 'Stop' } else { 'Warning' }
    if (-not (Show-DeleteConfirm $msg 'Alpheus - confirm delete' $icon)) { return }
    if ($permanent -and -not (Show-DeleteConfirm "Permanently delete $($ok.Count) item(s), $(Format-Size $total)?`n`nThere will be no Recycle Bin copy." 'Alpheus - permanent delete' 'Stop')) { return }

    $hwnd = [Windows.Interop.WindowInteropHelper]::new($Win).Handle
    $aborted = $false
    $rc = [Alpheus.Acheron]::Delete($hwnd, [string[]]@($ok | ForEach-Object { $_.FullPath }), $permanent, [ref]$aborted)
    $mode = if ($permanent) { 'PERMANENT' } else { 'RECYCLE' }
    $done = 0; $doneBytes = 0L; $failed = [Collections.Generic.List[string]]::new()
    $null = New-Item -ItemType Directory -Path (Split-Path $DeleteLog) -Force -ErrorAction SilentlyContinue
    foreach ($n in $ok) {
        $gone = -not (Test-Path -LiteralPath $n.FullPath)
        try { Add-Content -LiteralPath $DeleteLog -Value ("{0}`t{1}`t{2}`t{3}`t{4}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $mode, $(if ($gone) { 'OK' } else { 'NOT-DELETED' }), $n.Size, $n.FullPath) } catch { Write-Verbose "deletions.log: $_" }
        if ($gone) { $done++; $doneBytes += $n.Size; [Alpheus.Scanner]::Detach($n) } else { $failed.Add($n.FullPath) }
    }
    Update-AfterDelete
    $what = if ($permanent) { 'deleted permanently' } else { 'moved to the Recycle Bin' }
    $ui.lblStatus.Text = "Disk usage: $done item(s), $(Format-Size $doneBytes) $what$(if ($failed.Count) { "; $($failed.Count) not deleted" })$(if ($aborted) { ' (cancelled in Windows)' }). Log: $DeleteLog"
    if ($failed.Count -and -not $aborted) {
        Show-DeleteInfo "Not deleted (in use, access denied, or skipped in Windows' dialog; code $rc):`n`n$($failed -join "`n")" 'Warning'
    }
}

function Update-AfterDelete {
    # Rebuild the tree from the (now smaller) node graph, keeping what was expanded; refresh grid + treemap.
    $root = $script:Scanner.Root
    $expanded = [Collections.Generic.HashSet[object]]::new()
    $walk = { param($items) foreach ($it in $items) { if ($it -is [Windows.Controls.TreeViewItem] -and $it.IsExpanded -and $null -ne $it.Tag) { [void]$expanded.Add($it.Tag); & $walk $it.Items } } }
    & $walk $ui.tvDisk.Items
    Clear-Mark; $script:Anchor = $null
    $ui.tvDisk.Items.Clear()
    $top = New-NodeItem $root $root.Size
    [void]$ui.tvDisk.Items.Add($top)
    $open = { param($ti) if ($expanded.Contains($ti.Tag)) { Expand-NodeItem $ti; $ti.IsExpanded = $true; foreach ($c in @($ti.Items)) { if ($c -is [Windows.Controls.TreeViewItem] -and $null -ne $c.Tag) { & $open $c } } } }
    & $open $top
    Sync-TreeHeaderOffset
    Set-BigRows $script:Scanner
    $tmr = $script:TmRoot
    while ($tmr -and -not [Alpheus.Scanner]::IsAttached($tmr, $root)) { $tmr = $tmr.Parent }
    if (-not $script:Selected -or -not [Alpheus.Scanner]::IsAttached($script:Selected, $root)) { $script:Selected = $tmr }
    Set-TreemapRoot $(if ($tmr) { $tmr } else { $root })
    $ui.lblTm.Text = Get-NodeLabel $script:Selected
    if ($ui.lblScan.Text -notmatch 'Extensions tab updates on rescan') { $ui.lblScan.Text += '   |   items deleted: Extensions tab updates on rescan' }
}

function Get-MenuSource($menuItem) {
    $t = if ($menuItem.Parent -is [Windows.Controls.ContextMenu]) { $menuItem.Parent.PlacementTarget } else { $null }
    if ([object]::ReferenceEquals($t, $ui.tvDisk)) { 'tree' } elseif ([object]::ReferenceEquals($t, $ui.gridBig)) { 'grid' } else { 'treemap' }
}
function Get-MenuNode($menuItem) {
    if ((Get-MenuSource $menuItem) -eq 'grid') { $r = $ui.gridBig.SelectedItem; if ($r) { return $r.Node } }
    $script:Selected
}

function New-DiskMenu {
    $m = [Windows.Controls.ContextMenu]::new()
    $items = [ordered]@{
        'Open in Explorer'   = { param($s) Open-InExplorer (Get-MenuNode $s) }
        'Copy path'          = { param($s) $n = Get-MenuNode $s; if ($n) { [Windows.Clipboard]::SetText($n.FullPath) } }
        'Zoom treemap here'  = { param($s) Set-TreemapRoot (Get-DirOf (Get-MenuNode $s)) }
        'Rescan this folder' = { param($s) $d = Get-DirOf (Get-MenuNode $s); if ($d) { $ui.txtRoot.Text = $d.FullPath; Start-DiskScan $d.FullPath } }
        '-'                  = $null
        'Delete'             = { param($s) Invoke-DiskDelete (Get-MenuSource $s) $false }
        'Delete permanently...' = { param($s) Invoke-DiskDelete (Get-MenuSource $s) $true }
    }
    foreach ($k in $items.Keys) {
        if ($k -eq '-') { [void]$m.Items.Add([Windows.Controls.Separator]::new()); continue }
        $mi = [Windows.Controls.MenuItem]::new(); $mi.Header = $k; $mi.Add_Click($items[$k])
        if ($k -eq 'Delete') { $mi.InputGestureText = 'Del' } elseif ($k -like 'Delete perm*') { $mi.InputGestureText = 'Shift+Del' }
        [void]$m.Items.Add($mi)
    }
    $m
}

function Get-AncestorItem($d) {
    while ($null -ne $d -and $d -isnot [Windows.Controls.TreeViewItem]) {
        $d = if ($d -is [Windows.Media.Visual] -or $d -is [Windows.Media.Media3D.Visual3D]) { [Windows.Media.VisualTreeHelper]::GetParent($d) }
             else { [Windows.LogicalTreeHelper]::GetParent($d) }
    }
    $d
}

if ($script:ScanLoadError) {
    $ui.btnScan.IsEnabled = $false; $ui.btnBrowse.IsEnabled = $false
    $ui.lblScan.Text = "Disk scan engine failed to compile: $($script:ScanLoadError)"
} else {
    $ui.tvDisk.ContextMenu = New-DiskMenu
    $ui.imgTreemap.ContextMenu = New-DiskMenu
    $ui.gridBig.ContextMenu = New-DiskMenu
    $ui.gridBig.SelectionMode = 'Extended'
    Initialize-DeleteGuard

    $ui.btnScan.Add_Click({ Start-DiskScan $ui.txtRoot.Text })
    $ui.txtRoot.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Start-DiskScan $ui.txtRoot.Text } })
    $ui.btnScanCancel.Add_Click({ if ($script:Scanner) { $script:Scanner.Cancel(); $ui.lblScan.Text = 'Cancelling...' } })
    $ui.btnBrowse.Add_Click({
        $t = 'Microsoft.Win32.OpenFolderDialog' -as [type]
        if ($t) {
            $d = $t::new(); $d.Title = 'Folder to scan'
            if (Test-Path -LiteralPath $ui.txtRoot.Text) { $d.InitialDirectory = $ui.txtRoot.Text }
            if ($d.ShowDialog($Win)) { $ui.txtRoot.Text = $d.FolderName }
        } else {
            $f = (New-Object -ComObject Shell.Application).BrowseForFolder(0, 'Folder to scan', 0x41, 0)
            if ($f) { $ui.txtRoot.Text = $f.Self.Path }
        }
    })
    $ui.btnZoomOut.Add_Click({ if ($script:TmRoot -and $script:TmRoot.Parent) { Set-TreemapRoot $script:TmRoot.Parent } })

    $ui.tvDisk.AddHandler([Windows.Controls.TreeViewItem]::ExpandedEvent, [Windows.RoutedEventHandler]{
        param($s, $e) if ($e.OriginalSource -is [Windows.Controls.TreeViewItem]) { Expand-NodeItem $e.OriginalSource }
    })
    $ui.tvDisk.Add_SelectedItemChanged({
        $ti = $ui.tvDisk.SelectedItem
        if ($ti -is [Windows.Controls.TreeViewItem] -and $null -ne $ti.Tag) {
            $script:Selected = $ti.Tag; $ui.lblTm.Text = Get-NodeLabel $ti.Tag; Show-Highlight
        }
    })
    $ui.tvDisk.Add_PreviewMouseRightButtonDown({ param($s, $e)
        $ti = Get-AncestorItem $e.OriginalSource
        if ($ti) {
            # right-click inside the marked set keeps it; elsewhere it marks just that item
            if (-not $script:Marked.Contains($ti)) { Clear-Mark; Set-Mark $ti $true; $script:Anchor = $ti }
            $ti.IsSelected = $true; [void]$ti.Focus()
        }
    })
    $ui.tvDisk.Add_PreviewMouseLeftButtonDown({ param($s, $e)
        # Ctrl+click toggles, Shift+click marks a range, plain click marks one; the expander arrow is left alone
        for ($d = $e.OriginalSource; $null -ne $d -and $d -isnot [Windows.Controls.TreeViewItem];
             $d = $(if ($d -is [Windows.Media.Visual]) { [Windows.Media.VisualTreeHelper]::GetParent($d) } else { [Windows.LogicalTreeHelper]::GetParent($d) })) {
            if ($d -is [Windows.Controls.Primitives.ToggleButton]) { return }
        }
        $ti = Get-AncestorItem $e.OriginalSource
        if (-not $ti -or $null -eq $ti.Tag) { return }
        $mods = [Windows.Input.Keyboard]::Modifiers
        if ($mods -band [Windows.Input.ModifierKeys]::Control) { Set-Mark $ti (-not $script:Marked.Contains($ti)); $script:Anchor = $ti }
        elseif (($mods -band [Windows.Input.ModifierKeys]::Shift) -and $script:Anchor) {
            $vis = Get-VisibleItem; $a = $vis.IndexOf($script:Anchor); $b = $vis.IndexOf($ti)
            if ($a -ge 0 -and $b -ge 0) { Clear-Mark; foreach ($i in [math]::Min($a, $b)..[math]::Max($a, $b)) { Set-Mark $vis[$i] $true } }
        }
        else { Clear-Mark; Set-Mark $ti $true; $script:Anchor = $ti }
    })
    $ui.tvDisk.Add_KeyDown({ param($s, $e)
        if ($e.Key -eq 'Delete') { Invoke-DiskDelete 'tree' ([bool]([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Shift)); $e.Handled = $true }
    })
    $ui.gridBig.Add_PreviewKeyDown({ param($s, $e)
        if ($e.Key -eq 'Delete') { Invoke-DiskDelete 'grid' ([bool]([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Shift)); $e.Handled = $true }
    })
    $ui.tvDisk.Add_MouseDoubleClick({ param($s, $e)
        $ti = Get-AncestorItem $e.OriginalSource
        if ($ti -and $null -ne $ti.Tag -and -not $ti.Tag.IsFile) { Set-TreemapRoot $ti.Tag; $e.Handled = $true }
    })

    $ui.imgTreemap.Add_MouseMove({ param($s, $e)
        $it = Get-TmHit $e
        if ($it) { $ui.lblTm.Text = Get-NodeLabel $it.Node }
    })
    $ui.imgTreemap.Add_MouseLeave({ $ui.lblTm.Text = Get-NodeLabel $script:Selected })
    $ui.imgTreemap.Add_MouseLeftButtonDown({ param($s, $e)
        $it = Get-TmHit $e
        if (-not $it) { return }
        if ($e.ClickCount -ge 2) { Set-TreemapRoot (Get-DirOf $it.Node) }
        else { Set-DiskSelection $it.Node }
    })
    $ui.imgTreemap.Add_MouseRightButtonDown({ param($s, $e)
        $it = Get-TmHit $e
        if ($it) { Set-DiskSelection $it.Node }
    })
    $ui.tmGrid.Add_SizeChanged({ $RenderTimer.Stop(); $RenderTimer.Start() })   # window resize and every splitter drag land here

    # tree header: width drags and reorders on dgTree re-lay every realised row
    $ColTimer = [Windows.Threading.DispatcherTimer]::new(); $ColTimer.Interval = [TimeSpan]::FromMilliseconds(30)
    $ColTimer.Add_Tick({ $ColTimer.Stop(); Update-TreeColumns })
    $widthDesc = [ComponentModel.DependencyPropertyDescriptor]::FromProperty([Windows.Controls.DataGridColumn]::ActualWidthProperty, [Windows.Controls.DataGridColumn])
    foreach ($c in $ui.dgTree.Columns) { $widthDesc.AddValueChanged($c, [EventHandler]{ $ColTimer.Stop(); $ColTimer.Start() }) }
    $ui.dgTree.Add_ColumnDisplayIndexChanged({ $ColTimer.Stop(); $ColTimer.Start() })
    $ui.tvDisk.AddHandler([Windows.Controls.ScrollViewer]::ScrollChangedEvent, [Windows.Controls.ScrollChangedEventHandler]{
        param($s, $e) $ui.tvHeaderScroll.ScrollToHorizontalOffset($e.HorizontalOffset)
    })

    $ui.gridBig.Add_AutoGeneratingColumn({ param($s, $e) if ($e.PropertyName -eq 'Node') { $e.Cancel = $true } })
    $ui.gridBig.Add_MouseDoubleClick({
        $row = $ui.gridBig.SelectedItem
        if (-not $row) { return }
        if (-not ($script:Tm -and $script:Tm.Find($row.Node))) { Set-TreemapRoot $script:Scanner.Root }
        Set-DiskSelection $row.Node
    })
    $ui.gridTargets.Add_MouseDoubleClick({
        $row = $ui.gridTargets.SelectedItem
        if ($row -and $row.Path -and (Test-Path -LiteralPath $row.Path -PathType Container)) {
            $ui.txtRoot.Text = $row.Path; $ui.tabs.SelectedIndex = 3; Start-DiskScan $row.Path
        }
    })
}

# ---------------------------------------------------------------- Mnemosyne: layout memory
# Window bounds, every named splitter definition, tree column widths and DataGrid column widths/order go to
# %LOCALAPPDATA%\Alpheus\layout.json on close and come back on launch. Every read and write is guarded:
# a missing, corrupt or out-of-range value is skipped and that piece keeps its XAML default.
$LayoutPath  = Join-Path $env:LOCALAPPDATA 'Alpheus\layout.json'
$LayoutDefs  = 'colLeft', 'colTree', 'colRight', 'rowUpper', 'rowGrids', 'rowTm', 'rowLegend', 'rowTotals', 'rowTargets'
$LayoutGrids = 'gridTargets', 'gridExt', 'gridBig', 'dgTree'
$script:Layout = @{}

function Test-Finite($v, [double]$min, [double]$max) {
    try { $d = [double]$v } catch { return $false }
    -not [double]::IsNaN($d) -and -not [double]::IsInfinity($d) -and $d -ge $min -and $d -le $max
}

function Get-DefLength($def) { if ($def -is [Windows.Controls.ColumnDefinition]) { $def.Width } else { $def.Height } }
function Set-DefLength($def, $gl) { if ($def -is [Windows.Controls.ColumnDefinition]) { $def.Width = $gl } else { $def.Height = $gl } }

function Save-GridColumns([string]$name) {
    try {
        $g = $ui[$name]
        if (-not $g -or $g.Columns.Count -eq 0) { return }
        $script:Layout.Grids[$name] = @($g.Columns | ForEach-Object {
            @{ H = "$($_.Header)"; W = [math]::Round($_.ActualWidth, 1); I = $_.DisplayIndex } })
    } catch { }
}

function Restore-GridColumns([string]$name) {
    try {
        $saved = $script:Layout.Grids[$name]
        if ($null -eq $saved) { return }
        $g = $ui[$name]
        foreach ($s in (@($saved) | Where-Object { $_ -is [hashtable] } | Sort-Object { [int]$_.I })) {
            $c = $g.Columns | Where-Object { "$($_.Header)" -eq $s.H } | Select-Object -First 1
            if (-not $c) { continue }
            try { if (Test-Finite $s.W 20 4000) { $c.Width = [Windows.Controls.DataGridLength]::new([double]$s.W) } } catch { }
            try { if (Test-Finite $s.I 0 ($g.Columns.Count - 1)) { $c.DisplayIndex = [int]$s.I } } catch { }
        }
    } catch { }
}

function Import-Mnemosyne {
    $script:Layout = @{}
    try {
        if (Test-Path -LiteralPath $LayoutPath) {
            $j = Get-Content -LiteralPath $LayoutPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ($j -is [hashtable]) { $script:Layout = $j }
        }
    } catch { $script:Layout = @{} }   # corrupt file: defaults, and the next close overwrites it
    foreach ($k in 'Defs', 'Grids') { if ($script:Layout[$k] -isnot [hashtable]) { $script:Layout[$k] = @{} } }

    try {
        $w = $script:Layout['Window']
        if ($w -is [hashtable] -and (Test-Finite $w.Width $Win.MinWidth 20000) -and (Test-Finite $w.Height $Win.MinHeight 20000) -and
            (Test-Finite $w.Left -20000 20000) -and (Test-Finite $w.Top -20000 20000)) {
            # only if the title bar lands on a monitor that exists now (per monitor: a multi-monitor bounding box has dead zones)
            $l = [double]$w.Left; $t = [double]$w.Top
            $scale = [Windows.Forms.Screen]::PrimaryScreen.Bounds.Width / [Windows.SystemParameters]::PrimaryScreenWidth   # DIP -> px
            $grab = [Drawing.Point]::new([int](($l + [math]::Min(200, [double]$w.Width / 2)) * $scale), [int](($t + 12) * $scale))
            if (@([Windows.Forms.Screen]::AllScreens | Where-Object { $_.WorkingArea.Contains($grab) }).Count) {
                $Win.WindowStartupLocation = 'Manual'
                $Win.Left = $l; $Win.Top = $t; $Win.Width = [double]$w.Width; $Win.Height = [double]$w.Height
                if ($w.Maximized -eq $true) { $Win.WindowState = 'Maximized' }
            }
        }
    } catch { }

    foreach ($n in $LayoutDefs) {
        try {
            $v = $script:Layout.Defs[$n]; $def = $Win.FindName($n)
            if ($v -isnot [hashtable] -or -not $def) { continue }
            $u = [Windows.GridUnitType]"$($v.U)"
            if ($u -eq 'Auto') { Set-DefLength $def ([Windows.GridLength]::Auto) }
            elseif (Test-Finite $v.V 0.0001 20000) { Set-DefLength $def ([Windows.GridLength]::new([double]$v.V, $u)) }
        } catch { }
    }
    Restore-GridColumns 'dgTree'   # explicit columns: restored here, not on AutoGeneratedColumns
    try { ($ui.dgTree.Columns | Where-Object { $_.Header -eq 'Name' }).DisplayIndex = 0 } catch { }   # Name stays pinned first
    Update-TreeColumns
}

function Export-Mnemosyne {
    try {
        if ($Win.WindowState -eq 'Normal') {
            $script:Layout['Window'] = @{ Left = $Win.Left; Top = $Win.Top; Width = $Win.ActualWidth; Height = $Win.ActualHeight; Maximized = $false }
        } else {
            $rb = $Win.RestoreBounds
            if (-not $rb.IsEmpty) {
                $script:Layout['Window'] = @{ Left = $rb.Left; Top = $rb.Top; Width = $rb.Width; Height = $rb.Height
                                              Maximized = ($Win.WindowState -eq 'Maximized') }
            }
        }
    } catch { }
    foreach ($n in $LayoutDefs) {
        try { $gl = Get-DefLength ($Win.FindName($n)); $script:Layout.Defs[$n] = @{ V = $gl.Value; U = "$($gl.GridUnitType)" } } catch { }
    }
    foreach ($n in $LayoutGrids) { Save-GridColumns $n }
    try {
        $script:Layout['Version'] = 1
        $null = New-Item -ItemType Directory -Path (Split-Path $LayoutPath) -Force
        $tmp = "$LayoutPath.tmp"
        [IO.File]::WriteAllText($tmp, ($script:Layout | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $LayoutPath -Force   # whole-file swap: a crash mid-write cannot leave half a file
    } catch { }
}

foreach ($n in 'gridTargets', 'gridExt', 'gridBig') {
    $ui[$n].Add_AutoGeneratedColumns({ param($s, $e) Restore-GridColumns $s.Name })
}
Import-Mnemosyne

# a wide options panel must not starve the results pane when the window narrows (e.g. snapped on the 1080p display)
$Win.Add_SizeChanged({
    $room = $Win.ActualWidth - 28 - 12 - $Win.FindName('colMain').MinWidth - 16   # body margins, splitter, results min, frame
    $Win.FindName('colLeft').MaxWidth = [math]::Max(230, [math]::Min(560, $room))
})

# ---------------------------------------------------------------- handlers
$ui.btnAudit.Add_Click({ Start-AlpheusRun 'Audit' })
$ui.btnPreview.Add_Click({ Start-AlpheusRun 'Preview' })
$ui.btnApply.Add_Click({ Start-AlpheusRun 'Apply' })
$ui.btnStop.Add_Click({
    if (-not $script:Proc) { return }
    $msg = 'Kill the running Alpheus process?'
    if ($script:Mode -eq 'Apply') { $msg += "`n`nIf it is inside WUCache, wuauserv/bits stay stopped until you start them (or reboot)." }
    if ([Windows.MessageBox]::Show($msg, 'Alpheus', 'YesNo', 'Warning') -eq 'Yes') {
        try { $script:Proc.Kill($true) } catch { }
        $ui.lblStatus.Text = 'Stopped by user.'
    }
})
$ui.btnFolder.Add_Click({
    $d = Join-Path $env:LOCALAPPDATA 'Alpheus'
    $null = New-Item -ItemType Directory -Path $d -Force
    Start-Process explorer.exe $d
})
$ui.cb_CrashDumps.Add_Checked({ $ui.lblStatus.Text = 'CrashDumps ticked: run Audit first and read the Stability section before deleting evidence.' })
$Win.Add_Closing({
    param($s, $e)
    if ($script:Proc -and -not $script:Proc.HasExited) {
        if ([Windows.MessageBox]::Show('A run is still in progress. Kill it and close?', 'Alpheus', 'YesNo', 'Warning') -ne 'Yes') { $e.Cancel = $true; return }
        try { $script:Proc.Kill($true) } catch { }
    }
    $Timer.Stop(); $ScanTimer.Stop(); $RenderTimer.Stop()
    Export-Mnemosyne
    if ($script:Scanner -and -not $script:Scanner.IsCompleted) { $script:Scanner.Cancel(); [void]$script:Scanner.Wait(3000) }
})

[void]$Win.ShowDialog()
