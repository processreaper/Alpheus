#Requires -Version 7.0
<#
.SYNOPSIS
    Builds dist\Alpheus.exe: the launcher with the scripts and icon embedded.

.DESCRIPTION
    Compiles launcher\AlpheusLauncher.cs with the C# compiler that ships with .NET Framework 4.8
    (%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe), so no SDK is needed. The version is
    written into the assembly (Explorer > Properties > Details) and names the unpack folder.
#>
param(
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [string]$OutDir = (Join-Path (Split-Path $PSScriptRoot) 'dist')
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { throw "C# compiler not found at $csc (.NET Framework 4.8 is required to build)" }
$null = New-Item -ItemType Directory -Path $OutDir -Force
$obj = Join-Path $repo 'obj'; $null = New-Item -ItemType Directory -Path $obj -Force

# Generated: version constant + assembly metadata shown in Properties > Details.
@"
using System.Reflection;
[assembly: AssemblyTitle("Alpheus")]
[assembly: AssemblyDescription("Disk reclamation and performance audit for Windows")]
[assembly: AssemblyProduct("Alpheus")]
[assembly: AssemblyCompany("processreaper")]
[assembly: AssemblyCopyright("Copyright (c) 2026 processreaper. MIT License.")]
[assembly: AssemblyVersion("$Version.0")]
[assembly: AssemblyFileVersion("$Version.0")]
[assembly: AssemblyInformationalVersion("$Version")]
static class BuildInfo { public const string Version = "$Version"; }
"@ | Set-Content (Join-Path $obj 'BuildInfo.cs') -Encoding utf8

$payload = [ordered]@{
    'Start-AlpheusGui.ps1' = Join-Path $repo 'Start-AlpheusGui.ps1'
    'Invoke-Alpheus.ps1'   = Join-Path $repo 'Invoke-Alpheus.ps1'
    'alpheus.ico'          = Join-Path $repo 'assets\alpheus.ico'
    'LICENSE'              = Join-Path $repo 'LICENSE'
    'README.md'            = Join-Path $repo 'README.md'
}
$exe = Join-Path $OutDir 'Alpheus.exe'
$cscArgs = @('/nologo', '/target:winexe', '/optimize+', '/platform:anycpu', "/out:$exe",
    "/win32icon:$(Join-Path $repo 'assets\alpheus.ico')", "/win32manifest:$(Join-Path $repo 'launcher\app.manifest')",
    '/reference:System.Windows.Forms.dll') +
    @($payload.GetEnumerator() | ForEach-Object { "/resource:$($_.Value),$($_.Key)" }) +
    @((Join-Path $repo 'launcher\AlpheusLauncher.cs'), (Join-Path $obj 'BuildInfo.cs'))
& $csc @cscArgs
if ($LASTEXITCODE) { throw "csc failed ($LASTEXITCODE)" }
$f = Get-Item $exe
"built $exe  {0:N0} KB  version {1}" -f ($f.Length / 1KB), $f.VersionInfo.ProductVersion
