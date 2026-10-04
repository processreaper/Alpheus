#Requires -Version 7.0
<#
.SYNOPSIS
    Renders the Alpheus icon (gold stable arch framing treemap blocks, a river washing their base)
    to assets\alpheus.ico (16-256 px, PNG-compressed entries) and assets\alpheus-256.png.

.DESCRIPTION
    Sizes up to 32 px use a simplified drawing (three blocks, one wave, heavier strokes): the full
    drawing turns to noise at small sizes. Windows picks the closest stored size, so each one is
    drawn for its size rather than scaled down.
#>
param([string]$OutDir = (Join-Path (Split-Path $PSScriptRoot) 'assets'))

Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase
$null = New-Item -ItemType Directory -Path $OutDir -Force

function B($hex) { $b = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($hex)); $b.Freeze(); $b }
function G($a, $b) { $g = [Windows.Media.LinearGradientBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($a), [Windows.Media.ColorConverter]::ConvertFromString($b), 90); $g.Freeze(); $g }
function P([string]$d) { [Windows.Media.Geometry]::Parse($d) }
function Pen($brush, $w) { $p = [Windows.Media.Pen]::new($brush, $w); $p.StartLineCap = 'Round'; $p.EndLineCap = 'Round'; $p.LineJoin = 'Round'; $p }

# Both drawings use a 256 x 256 canvas.
$Full = {
    param($dc)
    $dc.DrawRoundedRectangle((G '#1C2129' '#0C0E12'), (Pen (B '#2A2E37') 4), [Windows.Rect]::new(8, 8, 240, 240), 48, 48)
    $dc.PushClip([Windows.Media.RectangleGeometry]::new([Windows.Rect]::new(10, 10, 236, 236), 46, 46))
    $dc.PushClip((P 'M 70,220 L 70,114 A 58,58 0 0 1 186,114 L 186,220 Z'))
    foreach ($c in @(@(70, 56, 64, 70, '#9B6BFF'), @(138, 56, 48, 40, '#F08A3C'), @(138, 100, 48, 26, '#4C8DF6'),
                      @(70, 130, 40, 60, '#57C46A'), @(114, 130, 72, 60, '#E5534B'))) {
        $dc.DrawRectangle((B $c[4]), (Pen (B '#0C0E12') 4), [Windows.Rect]::new($c[0], $c[1], $c[2], $c[3]))
    }
    $dc.Pop()
    $dc.DrawGeometry((B '#E60C0E12'), $null, (P 'M 10,176 C 60,150 96,200 136,178 S 206,152 246,170 L 246,246 L 10,246 Z'))
    $dc.DrawGeometry($null, (Pen (B '#5FB3B3') 16), (P 'M 18,176 C 60,152 96,198 136,178 S 204,154 240,168'))
    $dc.DrawGeometry($null, (Pen (B '#3CC7C7') 7), (P 'M 34,214 C 72,200 104,226 142,212 S 202,198 224,208'))
    $dc.DrawGeometry($null, (Pen (B '#E0B860') 16), (P 'M 70,226 L 70,114 A 58,58 0 0 1 186,114 L 186,226'))
    $dc.Pop()
}
$Small = {
    param($dc)
    $dc.DrawRoundedRectangle((G '#1C2129' '#0C0E12'), $null, [Windows.Rect]::new(0, 0, 256, 256), 52, 52)
    $dc.PushClip([Windows.Media.RectangleGeometry]::new([Windows.Rect]::new(0, 0, 256, 256), 52, 52))
    $dc.PushClip((P 'M 52,224 L 52,116 A 76,76 0 0 1 204,116 L 204,224 Z'))
    foreach ($c in @(@(52, 36, 84, 110, '#9B6BFF'), @(136, 36, 68, 110, '#F08A3C'), @(52, 146, 152, 60, '#57C46A'))) {
        $dc.DrawRectangle((B $c[4]), (Pen (B '#0C0E12') 10), [Windows.Rect]::new($c[0], $c[1], $c[2], $c[3]))
    }
    $dc.Pop()
    $dc.DrawGeometry((B '#0C0E12'), $null, (P 'M 0,178 C 60,148 100,206 140,178 S 216,150 256,170 L 256,256 L 0,256 Z'))
    $dc.DrawGeometry($null, (Pen (B '#5FB3B3') 30), (P 'M 6,178 C 60,150 100,204 140,178 S 214,152 250,168'))
    $dc.DrawGeometry($null, (Pen (B '#E0B860') 30), (P 'M 52,240 L 52,116 A 76,76 0 0 1 204,116 L 204,240'))
    $dc.Pop()
}

function Render($draw, [int]$size) {
    $dv = [Windows.Media.DrawingVisual]::new()
    $dc = $dv.RenderOpen(); $dc.PushTransform([Windows.Media.ScaleTransform]::new($size / 256.0, $size / 256.0)); & $draw $dc; $dc.Pop(); $dc.Close()
    $bmp = [Windows.Media.Imaging.RenderTargetBitmap]::new($size, $size, 96, 96, [Windows.Media.PixelFormats]::Pbgra32); $bmp.Render($dv); $bmp.Freeze(); $bmp
}
function PngBytes($bmp) {
    $e = [Windows.Media.Imaging.PngBitmapEncoder]::new(); $e.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $ms = [IO.MemoryStream]::new(); $e.Save($ms)
    , $ms.ToArray()   # comma: return the byte[] whole; PowerShell would otherwise unroll it into loose bytes
}

# ICO container: 6-byte header, 16-byte directory entry per image, then PNG payloads (Vista+ format).
$sizes = 16, 20, 24, 32, 40, 48, 64, 96, 128, 256
$images = [Collections.Generic.List[byte[]]]::new()
foreach ($s in $sizes) { $images.Add([byte[]](PngBytes (Render $(if ($s -le 32) { $Small } else { $Full }) $s))) }
$ms = [IO.MemoryStream]::new(); $w = [IO.BinaryWriter]::new($ms)
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $dim = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$images[$i].Length); $w.Write([uint32]$offset)
    $offset += $images[$i].Length
}
foreach ($img in $images) { $w.Write($img) }
$w.Flush()
[IO.File]::WriteAllBytes((Join-Path $OutDir 'alpheus.ico'), $ms.ToArray())
[IO.File]::WriteAllBytes((Join-Path $OutDir 'alpheus-256.png'), (PngBytes (Render $Full 256)))
"wrote $(Join-Path $OutDir 'alpheus.ico') ($($sizes -join ', ') px) and alpheus-256.png"
