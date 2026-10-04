// Alpheus.exe - launcher for the Alpheus PowerShell GUI.
//
// Carries Start-AlpheusGui.ps1, Invoke-Alpheus.ps1 and the icon as embedded resources. On each run it:
//   1. finds PowerShell 7 (pwsh.exe), or explains how to install it;
//   2. unpacks the resources to %LOCALAPPDATA%\Alpheus\app\<version> (rewritten if they differ, so a
//      tampered or partial copy is repaired) and removes older version folders;
//   3. asks for elevation as itself, so UAC names "Alpheus" rather than PowerShell; if declined, runs
//      unelevated with partial results, as the script does;
//   4. starts the GUI with no console window, then exits.
//
// Switches: --no-elevate  skip the UAC request.  --uninstall  remove %LOCALAPPDATA%\Alpheus (asks first).
//           (--elevated is internal: marks the relaunched copy.)
// ALPHEUS_PWSH overrides the pwsh.exe path (used by tests).
// Targets .NET Framework 4.8, which ships with Windows 10/11, so the .exe needs nothing installed.

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Principal;
using System.Windows.Forms;
using Microsoft.Win32;

static class AlpheusLauncher
{
    static readonly string[] Payload = { "Start-AlpheusGui.ps1", "Invoke-Alpheus.ps1", "alpheus.ico", "LICENSE", "README.md" };
    const int ErrorCancelled = 1223;   // ERROR_CANCELLED: the user said No at UAC

    [STAThread]
    static int Main(string[] args)
    {
        try
        {
            if (args.Contains("--uninstall", StringComparer.OrdinalIgnoreCase)) return Uninstall();
            bool noElevate = args.Contains("--no-elevate", StringComparer.OrdinalIgnoreCase);
            bool relaunched = args.Contains("--elevated", StringComparer.OrdinalIgnoreCase);

            string pwsh = FindPwsh();
            if (pwsh == null) { ExplainMissingPwsh(); return 1; }

            if (!noElevate && !relaunched && !IsAdmin())
            {
                try
                {
                    Process.Start(new ProcessStartInfo(Application.ExecutablePath, "--elevated") { UseShellExecute = true, Verb = "runas" });
                    return 0;
                }
                catch (Win32Exception e)
                {
                    if (e.NativeErrorCode != ErrorCancelled) throw;   // declined: carry on unelevated
                }
            }

            string dir = Unpack();
            var psi = new ProcessStartInfo(pwsh,
                "-NoProfile -ExecutionPolicy Bypass -STA -File \"" + Path.Combine(dir, "Start-AlpheusGui.ps1") + "\" -NoElevate")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = dir
            };
            Process.Start(psi);
            return 0;
        }
        catch (Exception e)
        {
            MessageBox.Show("Alpheus could not start:\n\n" + e.Message, "Alpheus", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 2;
        }
    }

    // Alpheus installs nothing system-wide: no registry keys, services, scheduled tasks or shortcuts.
    // Everything lives under %LOCALAPPDATA%\Alpheus. Removes the unpacked app always, and logs, layout and
    // config only if the user says so; the .exe itself is deleted by the user.
    static int Uninstall()
    {
        string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Alpheus");
        if (!Directory.Exists(root))
        {
            MessageBox.Show("Nothing to remove: " + root + " does not exist.\n\nDelete Alpheus.exe to finish.", "Alpheus - uninstall");
            return 0;
        }
        var r = MessageBox.Show(
            "Remove Alpheus from this PC?\n\nThe unpacked program in\n    " + Path.Combine(root, "app") + "\nwill be removed.\n\n" +
            "Also remove your reports, delete log, window layout and alpheus.config.json in\n    " + root + " ?\n\n" +
            "Yes = remove everything   No = keep reports and settings   Cancel = do nothing",
            "Alpheus - uninstall", MessageBoxButtons.YesNoCancel, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2);
        if (r == DialogResult.Cancel) return 1;
        try
        {
            if (r == DialogResult.Yes) Directory.Delete(root, true);
            else if (Directory.Exists(Path.Combine(root, "app"))) Directory.Delete(Path.Combine(root, "app"), true);
        }
        catch (Exception e)
        {
            MessageBox.Show("Could not remove everything (is Alpheus still open?):\n\n" + e.Message, "Alpheus - uninstall", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return 2;
        }
        MessageBox.Show("Alpheus has been removed" + (r == DialogResult.Yes ? "." : "; your reports and settings were kept in " + root + ".") +
            "\n\nDelete Alpheus.exe to finish.", "Alpheus - uninstall", MessageBoxButtons.OK, MessageBoxIcon.Information);
        return 0;
    }

    static bool IsAdmin()
    {
        return new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);
    }

    static string FindPwsh()
    {
        string over = Environment.GetEnvironmentVariable("ALPHEUS_PWSH");
        if (!string.IsNullOrEmpty(over)) return IsPwsh7(over) ? over : null;

        var candidates = new List<string>();
        candidates.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"PowerShell\7\pwsh.exe"));
        using (var k = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\pwsh.exe"))
        {
            string reg = k == null ? null : k.GetValue(null) as string;
            if (!string.IsNullOrEmpty(reg)) candidates.Add(reg.Trim('"'));
        }
        foreach (string p in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'))
            if (p.Trim().Length > 0) candidates.Add(Path.Combine(p.Trim(), "pwsh.exe"));
        candidates.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Microsoft\WindowsApps\pwsh.exe"));
        return candidates.FirstOrDefault(IsPwsh7);
    }

    static bool IsPwsh7(string path)
    {
        try
        {
            if (!File.Exists(path)) return false;
            var v = FileVersionInfo.GetVersionInfo(path);
            return v.ProductMajorPart == 0 || v.ProductMajorPart >= 7;   // 0: Store alias stub, no version resource
        }
        catch { return false; }
    }

    static void ExplainMissingPwsh()
    {
        var r = MessageBox.Show(
            "Alpheus needs PowerShell 7 (pwsh), which is not installed.\n\n" +
            "Install it from a terminal with:\n    winget install --id Microsoft.PowerShell\n\n" +
            "Or open the download page now?",
            "Alpheus - PowerShell 7 required", MessageBoxButtons.YesNo, MessageBoxIcon.Information);
        if (r == DialogResult.Yes) Process.Start(new ProcessStartInfo("https://aka.ms/powershell") { UseShellExecute = true });
    }

    static string Unpack()
    {
        string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Alpheus\app");
        string dir = Path.Combine(root, BuildInfo.Version);
        Directory.CreateDirectory(dir);
        var asm = Assembly.GetExecutingAssembly();
        foreach (string name in Payload)
        {
            byte[] want;
            using (var s = asm.GetManifestResourceStream(name))
            {
                if (s == null) throw new InvalidOperationException("embedded file missing: " + name);
                using (var ms = new MemoryStream()) { s.CopyTo(ms); want = ms.ToArray(); }
            }
            string target = Path.Combine(dir, name);
            if (File.Exists(target) && File.ReadAllBytes(target).SequenceEqual(want)) continue;
            string tmp = target + ".tmp";
            File.WriteAllBytes(tmp, want);
            if (File.Exists(target)) File.Delete(target);
            File.Move(tmp, target);
        }
        foreach (string old in Directory.GetDirectories(root))   // older versions: best effort, never fatal
            if (!string.Equals(Path.GetFileName(old), BuildInfo.Version, StringComparison.OrdinalIgnoreCase))
                try { Directory.Delete(old, true); } catch { }
        return dir;
    }
}
