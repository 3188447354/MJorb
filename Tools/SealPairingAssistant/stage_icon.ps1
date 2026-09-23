param(
    [Parameter(Mandatory = $true)]
    [string]$Source,

    [Parameter(Mandatory = $true)]
    [string]$UpstreamRoot
)

$ErrorActionPreference = "Stop"

$sourcePath = (Resolve-Path $Source).Path
$upstreamPath = (Resolve-Path $UpstreamRoot).Path
$runtimeIcon = Join-Path $upstreamPath "icon.png"
$resourceIcon = Join-Path $upstreamPath "icon.ico"
$uiAssetDirectory = Join-Path $upstreamPath "src/seal_assets"
$uiIcon = Join-Path $uiAssetDirectory "seal_icon_ui.rgba"
$temporaryDirectory = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$tempPng = Join-Path $temporaryDirectory "seal-pairing-icon-256.png"

Add-Type -AssemblyName System.Drawing

$image = [System.Drawing.Image]::FromFile($sourcePath)
try {
    if ($image.Width -lt 256 -or $image.Height -lt 256) {
        throw "Seal app icon must be at least 256x256, got $($image.Width)x$($image.Height)"
    }

    $bitmap = New-Object System.Drawing.Bitmap 256, 256, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([System.Drawing.Color]::Transparent)
            $path = New-Object System.Drawing.Drawing2D.GraphicsPath
            try {
                # Use one rounded source for the executable and the in-window texture.
                $diameter = 52
                $path.AddArc(0, 0, $diameter, $diameter, 180, 90)
                $path.AddArc(256 - $diameter, 0, $diameter, $diameter, 270, 90)
                $path.AddArc(256 - $diameter, 256 - $diameter, $diameter, $diameter, 0, 90)
                $path.AddArc(0, 256 - $diameter, $diameter, $diameter, 90, 90)
                $path.CloseFigure()
                $graphics.SetClip($path)
            }
            finally {
                $path.Dispose()
            }
            $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceOver
            $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.DrawImage(
                $image,
                [System.Drawing.Rectangle]::new(0, 0, 256, 256),
                0,
                0,
                $image.Width,
                $image.Height,
                [System.Drawing.GraphicsUnit]::Pixel
            )
        }
        finally {
            $graphics.Dispose()
        }

        $bitmap.Save($tempPng, [System.Drawing.Imaging.ImageFormat]::Png)

        New-Item -ItemType Directory -Force -Path $uiAssetDirectory | Out-Null
        $uiBitmap = New-Object System.Drawing.Bitmap 160, 160, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            $uiGraphics = [System.Drawing.Graphics]::FromImage($uiBitmap)
            try {
                $uiGraphics.Clear([System.Drawing.Color]::Transparent)
                $uiGraphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
                $uiGraphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $uiGraphics.DrawImage($bitmap, [System.Drawing.Rectangle]::new(0, 0, 160, 160))
            }
            finally {
                $uiGraphics.Dispose()
            }

            $rgba = New-Object byte[] (160 * 160 * 4)
            for ($y = 0; $y -lt 160; $y++) {
                for ($x = 0; $x -lt 160; $x++) {
                    $color = $uiBitmap.GetPixel($x, $y)
                    $offset = ($y * 160 + $x) * 4
                    $rgba[$offset] = $color.R
                    $rgba[$offset + 1] = $color.G
                    $rgba[$offset + 2] = $color.B
                    $rgba[$offset + 3] = $color.A
                }
            }
            [System.IO.File]::WriteAllBytes($uiIcon, $rgba)
        }
        finally {
            $uiBitmap.Dispose()
        }
    }
    finally {
        $bitmap.Dispose()
    }
}
finally {
    $image.Dispose()
}

$pngBytes = [System.IO.File]::ReadAllBytes($tempPng)
$stream = [System.IO.File]::Create($resourceIcon)
try {
    $writer = New-Object System.IO.BinaryWriter($stream)
    try {
        # ICONDIR
        $writer.Write([UInt16]0) # reserved
        $writer.Write([UInt16]1) # icon
        $writer.Write([UInt16]1) # one image

        # ICONDIRENTRY. Width/height 0 means 256 pixels.
        $writer.Write([Byte]0)
        $writer.Write([Byte]0)
        $writer.Write([Byte]0)   # palette size
        $writer.Write([Byte]0)   # reserved
        $writer.Write([UInt16]1) # color planes
        $writer.Write([UInt16]32)
        $writer.Write([UInt32]$pngBytes.Length)
        $writer.Write([UInt32]22)
        $writer.Write($pngBytes)
    }
    finally {
        $writer.Dispose()
    }
}
finally {
    $stream.Dispose()
}

Remove-Item $tempPng -Force -ErrorAction SilentlyContinue

if ((Get-Item $uiIcon).Length -ne (160 * 160 * 4)) {
    throw "Generated Seal UI icon has an unexpected size"
}
if ((Get-Item $resourceIcon).Length -lt 1024) {
    throw "Generated Windows icon resource is unexpectedly small"
}

Write-Host "Rounded Seal app icon staged for runtime, Windows PE resource, and UI texture."
Write-Host "Source: $sourcePath"
Write-Host "Runtime PNG: $runtimeIcon"
Write-Host "Windows ICO: $resourceIcon"
