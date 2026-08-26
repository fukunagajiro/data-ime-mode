# extension\icons\*.png を生成する。拡張機能の動作には関わらない開発用スクリプト。
#
#   powershell -ExecutionPolicy Bypass -File tools\make-icons.ps1
#
# 角丸の背景に「あ」を 1 文字。16px でも潰れないよう、字は大きめに置く。

Add-Type -AssemblyName System.Drawing

$outDir = Join-Path $PSScriptRoot '..\extension\icons'
$outDir = [IO.Path]::GetFullPath($outDir)
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$bg   = [Drawing.Color]::FromArgb(255, 59, 91, 219)   # #3B5BDB
$fg   = [Drawing.Color]::White
$font = if ([Drawing.FontFamily]::Families.Name -contains 'Yu Gothic UI') { 'Yu Gothic UI' } else { 'Meiryo' }

foreach ($size in 16, 32, 48, 128) {
    $bmp = New-Object Drawing.Bitmap($size, $size)
    $g   = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([Drawing.Color]::Transparent)

    # 角丸の背景
    $r    = [Math]::Max(2, [int]($size * 0.22))
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $d    = $r * 2
    $max  = $size - 1
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc($max - $d, 0, $d, $d, 270, 90)
    $path.AddArc($max - $d, $max - $d, $d, $d, 0, 90)
    $path.AddArc(0, $max - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $g.FillPath((New-Object Drawing.SolidBrush($bg)), $path)

    # 「あ」を中央へ
    $f  = New-Object Drawing.Font($font, [float]($size * 0.78), [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
    $sf = New-Object Drawing.StringFormat
    $sf.Alignment     = 'Center'
    $sf.LineAlignment = 'Center'
    $rect = New-Object Drawing.RectangleF(0, [float]($size * 0.02), [float]$size, [float]$size)
    $g.DrawString('あ', $f, (New-Object Drawing.SolidBrush($fg)), $rect, $sf)

    $g.Dispose()
    $out = Join-Path $outDir "icon$size.png"
    $bmp.Save($out, [Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host "生成: $out"
}
