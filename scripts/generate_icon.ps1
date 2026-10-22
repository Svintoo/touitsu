# Regenerate the outlined SVG and Windows icon using the bundled Japanese font.
# Requires Windows PowerShell/System.Drawing and ImageMagick.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot -Parent
$fonts = New-Object System.Drawing.Text.PrivateFontCollection
$fonts.AddFontFile((Join-Path $root 'src/fonts/jp.ttf'))
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$label = [string][char]0x7d71 + '1'
$offset = 0
foreach ($character in $label.ToCharArray()) {
    $glyph = New-Object System.Drawing.Drawing2D.GraphicsPath
    $glyph.AddString([string]$character, $fonts.Families[0], 0, 180, [System.Drawing.PointF]::new(0, 0), [System.Drawing.StringFormat]::GenericTypographic)
    $glyphBounds = $glyph.GetBounds()
    $position = [System.Drawing.Drawing2D.Matrix]::new()
    $position.Translate($offset - $glyphBounds.X, 0)
    $glyph.Transform($position)
    $path.AddPath($glyph, $false)
    $offset += $glyphBounds.Width + 18
    $position.Dispose()
    $glyph.Dispose()
}
$bounds = $path.GetBounds()
$scale = [Math]::Min(480 / $bounds.Width, 480 / $bounds.Height)
$matrix = [System.Drawing.Drawing2D.Matrix]::new($scale, 0, 0, $scale, (512 - $bounds.Width * $scale) / 2 - $bounds.X * $scale, (512 - $bounds.Height * $scale) / 2 - $bounds.Y * $scale)
$path.Transform($matrix)
$points = $path.PathPoints
$types = $path.PathTypes
$commands = [System.Collections.Generic.List[string]]::new()
function PointText($point) { $point.X.ToString('0.###', [cultureinfo]::InvariantCulture) + ' ' + $point.Y.ToString('0.###', [cultureinfo]::InvariantCulture) }
for ($i = 0; $i -lt $points.Length; $i++) {
    switch ($types[$i] -band 7) {
        0 { $commands.Add('M' + (PointText $points[$i])) }
        1 { $commands.Add('L' + (PointText $points[$i])) }
        3 {
            $commands.Add('C' + (PointText $points[$i]) + ' ' + (PointText $points[$i+1]) + ' ' + (PointText $points[$i+2]))
            $i += 2
        }
    }
    if ($types[$i] -band 128) { $commands.Add('Z') }
}
$svg = @"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512" role="img" aria-labelledby="title">
  <title id="title">Touitsu - $label</title>
  <path fill="none" stroke="#000000" stroke-width="14" stroke-linejoin="round" d="$($commands -join ' ')"/>
  <path fill="#ffffff" fill-rule="nonzero" d="$($commands -join ' ')"/>
</svg>
"@
$svgPath = Join-Path $root 'src/icons/touitsu.svg'
[IO.File]::WriteAllText($svgPath, $svg, [Text.UTF8Encoding]::new($false))
& magick -background none $svgPath -define icon:auto-resize=256,128,64,48,32,24,16 (Join-Path $root 'src/icons/touitsu.ico')
if ($LASTEXITCODE -ne 0) { throw 'Icon conversion failed' }
$matrix.Dispose()
$path.Dispose()
$fonts.Dispose()
