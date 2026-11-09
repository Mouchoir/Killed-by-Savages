<#
.SYNOPSIS
    Draws the addon's icon (minimap button, addon list) from the guild logo.
.DESCRIPTION
    Reads art\savages-logo.svg, the Savages logo: a 512 square of one colour
    (its rect) with the claw marks on it (one path of cubic curves, absolute
    commands). Draws it as a disc, the claws inside, at 512 px with
    antialiasing, scales it down to -Size px and writes a 32-bit TGA with
    alpha, the format the game loads: addon\KilledBySavages\Media\Logo.tga.
    The disc leaves a margin: the minimap button crops 5 % off each side of
    its icon. -PreviewPng also writes the icon as a PNG, to look at it.
#>
param(
    [string]$Svg = (Join-Path $PSScriptRoot '..\art\savages-logo.svg'),
    [string]$Out = (Join-Path $PSScriptRoot '..\addon\KilledBySavages\Media\Logo.tga'),
    [int]$Size = 64,
    [string]$PreviewPng
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$text = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Svg))
$discHex = [regex]::Match($text, '<rect[^>]*fill="(#[0-9A-Fa-f]{6})"').Groups[1].Value
$pathMatch = [regex]::Match($text, '<path[^>]*\sd="([^"]+)"[^>]*fill="(#[0-9A-Fa-f]{6})"')
$d = $pathMatch.Groups[1].Value
$clawHex = $pathMatch.Groups[2].Value
if (-not $discHex -or -not $d -or -not $clawHex) { throw "Not the expected logo SVG: $Svg" }

$canvas = 512
$disc = 0.875                                   # disc radius, as a share of half the canvas
$centre = $canvas / 2
function Place([double]$value) { [single]($centre + ($value - $centre) * $disc) }

# The claws, in absolute commands: M x y, then L x y or C x1 y1 x2 y2 x y
# (each repeated while numbers follow), then Z.
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$tokens = @([regex]::Matches($d, '[MLCZ]|-?[0-9]*\.?[0-9]+') | ForEach-Object { $_.Value })
$index = 0
$current = $null
$command = $null
function Next { $script:index++; return [double]$tokens[$script:index - 1] }
while ($index -lt $tokens.Count) {
    $token = $tokens[$index]
    if ($token -match '^[MLCZ]$') {
        $command = $token
        $index++
        if ($command -eq 'Z') { $path.CloseFigure(); $command = $null }
        elseif ($command -eq 'M') { $path.StartFigure() }
        continue
    }
    if ($command -eq 'M') {
        $current = New-Object System.Drawing.PointF (Place (Next)), (Place (Next))
        $command = 'L'                          # more numbers after M are line points
    } elseif ($command -eq 'L') {
        $point = New-Object System.Drawing.PointF (Place (Next)), (Place (Next))
        $path.AddLine($current, $point)
        $current = $point
    } elseif ($command -eq 'C') {
        $c1 = New-Object System.Drawing.PointF (Place (Next)), (Place (Next))
        $c2 = New-Object System.Drawing.PointF (Place (Next)), (Place (Next))
        $end = New-Object System.Drawing.PointF (Place (Next)), (Place (Next))
        $path.AddBezier($current, $c1, $c2, $end)
        $current = $end
    } else {
        throw "Unexpected path data near token $index of $Svg"
    }
}

$big = New-Object System.Drawing.Bitmap $canvas, $canvas, ([System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
$graphics = [System.Drawing.Graphics]::FromImage($big)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.Clear([System.Drawing.Color]::Transparent)
$radius = $centre * $disc
$discBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($discHex))
$graphics.FillEllipse($discBrush, [single]($centre - $radius), [single]($centre - $radius), [single](2 * $radius), [single](2 * $radius))
$clawBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($clawHex))
$graphics.FillPath($clawBrush, $path)
$graphics.Dispose()

# Scaled down in premultiplied colour, so the edge of the disc keeps its red.
$small = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
$graphics = [System.Drawing.Graphics]::FromImage($small)
$graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
$graphics.Clear([System.Drawing.Color]::Transparent)
$attributes = New-Object System.Drawing.Imaging.ImageAttributes
$attributes.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
$graphics.DrawImage($big, (New-Object System.Drawing.Rectangle 0, 0, $Size, $Size), 0, 0, $canvas, $canvas, [System.Drawing.GraphicsUnit]::Pixel, $attributes)
$graphics.Dispose()

# TGA: uncompressed true colour, 32 bits, 8 of alpha, rows from the bottom.
$bytes = New-Object byte[] (18 + $Size * $Size * 4)
$bytes[2] = 2
$bytes[12] = [byte]($Size -band 0xFF)
$bytes[13] = [byte](($Size -shr 8) -band 0xFF)
$bytes[14] = [byte]($Size -band 0xFF)
$bytes[15] = [byte](($Size -shr 8) -band 0xFF)
$bytes[16] = 32
$bytes[17] = 8
$at = 18
for ($y = $Size - 1; $y -ge 0; $y--) {
    for ($x = 0; $x -lt $Size; $x++) {
        $pixel = $small.GetPixel($x, $y)
        $bytes[$at] = $pixel.B
        $bytes[$at + 1] = $pixel.G
        $bytes[$at + 2] = $pixel.R
        $bytes[$at + 3] = $pixel.A
        $at += 4
    }
}
$target = [System.IO.Path]::GetFullPath($Out)
New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
[System.IO.File]::WriteAllBytes($target, $bytes)
if ($PreviewPng) { $small.Save([System.IO.Path]::GetFullPath($PreviewPng), [System.Drawing.Imaging.ImageFormat]::Png) }
$small.Dispose()
$big.Dispose()
Write-Host "Icon written -> $target ($Size x $Size)"
