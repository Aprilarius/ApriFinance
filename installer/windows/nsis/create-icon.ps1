$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
# Same geometric mark as assets/branding/aprifinance.svg; no font dependency.
$pngs = [Collections.Generic.List[byte[]]]::new()
$sizes = @(16, 24, 32, 48, 64, 128, 256)
foreach ($size in $sizes) {
    $bitmap = [Drawing.Bitmap]::new($size, $size)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([Drawing.Color]::Transparent)
    $graphics.ScaleTransform($size / 256.0, $size / 256.0)
    $shape = [Drawing.Drawing2D.GraphicsPath]::new()
    foreach ($arc in @(@(0,0,180), @(160,0,270), @(160,160,0), @(0,160,90))) {
        $shape.AddArc($arc[0], $arc[1], 96, 96, $arc[2], 90)
    }
    $shape.CloseFigure()
    $green = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#25634A'))
    $graphics.FillPath($green, $shape)
    $points = [Drawing.PointF[]]@([Drawing.PointF]::new(56,196), [Drawing.PointF]::new(111,56), [Drawing.PointF]::new(145,56), [Drawing.PointF]::new(200,196), [Drawing.PointF]::new(165,196), [Drawing.PointF]::new(128,95), [Drawing.PointF]::new(91,196))
    $graphics.FillPolygon([Drawing.Brushes]::White, $points)
    $graphics.FillRectangle([Drawing.Brushes]::White, 92, 153, 72, 26)
    $stream = [IO.MemoryStream]::new()
    $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
    $pngs.Add($stream.ToArray())
    if ($size -eq 256) { [IO.File]::WriteAllBytes((Join-Path $projectRoot 'assets/branding/aprifinance.png'), $stream.ToArray()) }
    $stream.Dispose(); $shape.Dispose(); $green.Dispose(); $graphics.Dispose(); $bitmap.Dispose()
}
$file = [IO.File]::Create((Join-Path $projectRoot 'windows/runner/resources/app_icon.ico'))
$writer = [IO.BinaryWriter]::new($file)
try {
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $dimension = if ($sizes[$i] -eq 256) { 0 } else { $sizes[$i] }
        $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
        $writer.Write([byte]0); $writer.Write([byte]0)
        $writer.Write([uint16]1); $writer.Write([uint16]32)
        $writer.Write([uint32]$pngs[$i].Length); $writer.Write([uint32]$offset)
        $offset += $pngs[$i].Length
    }
    foreach ($png in $pngs) { $writer.Write($png) }
} finally { $writer.Dispose() }
