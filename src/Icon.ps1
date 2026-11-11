# Icon generation: recolours the installed Claude icon (generated locally, nothing is redistributed).
Add-Type -AssemblyName System.Drawing

function Get-ClaudePackage {
  # 解析顺序（不写死包名，任一命中即返回）：
  #   1) 拥有已落盘执行别名的包 —— 这是 launcher 真正启动的通道，必须最优先
  #   2) 旧标识 AnthropicPBC.Claude（Microsoft Store 渠道，历史上一直是这个）
  #   3) 任何名字含 Claude 且真的有 app\Claude.exe 的包
  #
  # 2026-11-11 教训：5.1231.2 同时存在两套包标识 ——
  #   AnthropicPBC.Claude_fnn82j28hfe8t（Store，Publisher=CN=0ED83B57-…）
  #   Claude_pzs8sxrjxfjjc（官方直装，Publisher=CN="Anthropic, PBC"…）
  # 旧代码写死 Get-AppxPackage AnthropicPBC.Claude，官方一旦弃用旧标识就直接抛异常。
  $all = @(Get-AppxPackage | Where-Object { $_.Name -like '*Claude*' -and $_.InstallLocation } |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.InstallLocation 'app\Claude.exe') })
  if (-not $all.Count) { throw 'Claude Desktop (MSIX) is not installed.' }

  $aliasDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
  $aliasCandidates = @('claude-desktop-msstore.exe', 'claude-desktop.exe')

  foreach ($a in $aliasCandidates) {
    if (-not (Test-Path -LiteralPath (Join-Path $aliasDir $a))) { continue }
    foreach ($p in $all) {
      $manifest = Join-Path $p.InstallLocation 'AppxManifest.xml'
      if (-not (Test-Path -LiteralPath $manifest)) { continue }
      $raw = Get-Content -LiteralPath $manifest -Raw -ErrorAction SilentlyContinue
      if ($raw -and $raw.Contains($a)) { return $p }
    }
  }

  $legacy = $all | Where-Object { $_.Name -eq 'AnthropicPBC.Claude' } | Sort-Object Version -Descending | Select-Object -First 1
  if ($legacy) { return $legacy }
  $all | Sort-Object Version -Descending | Select-Object -First 1
}

function Get-ClaudeAliasExe {
  # 返回 launcher 应当使用的执行别名（存在才返回），否则空串。
  $aliasDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
  foreach ($a in @('claude-desktop-msstore.exe', 'claude-desktop.exe')) {
    $p = Join-Path $aliasDir $a
    if (Test-Path -LiteralPath $p) { return $p }
  }
  ''
}

function Resolve-Palette($spec, $palettes) {
  if ($spec -is [string] -and $spec -match '^#?([0-9a-fA-F]{6})$') {            # custom colour: any #RRGGBB
    $c = [Drawing.ColorTranslator]::FromHtml('#' + $Matches[1])
    $mx = [Math]::Max([Math]::Max($c.R, $c.G), $c.B) / 255.0; $mn = [Math]::Min([Math]::Min($c.R, $c.G), $c.B) / 255.0
    $s = if ($mx -eq 0) { 0 } else { ($mx - $mn) / $mx }
    return @{ hue = [double]$c.GetHue(); sat = [Math]::Max(0.35, $s); vMin = 0.15 * $mx; vMax = [Math]::Max(0.35, $mx); glyph = '#FFFFFF' }
  }
  $p = $palettes.$spec
  if (-not $p) { throw "Unknown palette '$spec'. Use a name from palettes.json or a #RRGGBB colour." }
  @{ hue = [double]$p.hue; sat = [double]$p.sat; vMin = [double]$p.vMin; vMax = [double]$p.vMax; glyph = [string]$p.glyph }
}

function Get-IconBase($pkg) {
  $src = [Drawing.Bitmap]::FromFile((Join-Path $pkg.InstallLocation 'assets\Square310x310Logo.scale-400.png'))
  $minX = $src.Width; $minY = $src.Height; $maxX = 0; $maxY = 0
  for ($y = 0; $y -lt $src.Height; $y += 2) { for ($x = 0; $x -lt $src.Width; $x += 2) {
    if ($src.GetPixel($x, $y).A -gt 40) { if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x }; if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y } } } }
  $side = [Math]::Max($maxX - $minX, $maxY - $minY) + 2
  $S = 256
  $base = New-Object Drawing.Bitmap $S, $S, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [Drawing.Graphics]::FromImage($base); $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'
  $g.DrawImage($src, [Drawing.Rectangle]::new(0, 0, $S, $S), [Drawing.Rectangle]::new($minX, $minY, $side, $side), 'Pixel'); $g.Dispose(); $src.Dispose()
  $base
}

function ConvertFrom-Hsv($h, $s, $v) {
  $h6 = ($h % 360) / 60.0; $i = [Math]::Floor($h6); $f = $h6 - $i
  $p = $v * (1 - $s); $q = $v * (1 - $s * $f); $t = $v * (1 - $s * (1 - $f))
  switch ([int]$i % 6) { 0 { $v, $t, $p } 1 { $q, $v, $p } 2 { $p, $v, $t } 3 { $p, $q, $v } 4 { $t, $p, $v } default { $v, $p, $q } }
}

function Convert-IconBase($base, $pal) {
  $S = $base.Width; $out = New-Object Drawing.Bitmap $S, $S, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $gl = [Drawing.ColorTranslator]::FromHtml($pal.glyph)
  for ($y = 0; $y -lt $S; $y++) { for ($x = 0; $x -lt $S; $x++) {
    $p = $base.GetPixel($x, $y)
    if ($p.A -eq 0) { $out.SetPixel($x, $y, $p); continue }
    $mx = [Math]::Max([Math]::Max($p.R, $p.G), $p.B); $mn = [Math]::Min([Math]::Min($p.R, $p.G), $p.B)
    $val = $mx / 255.0; $sat = if ($mx -eq 0) { 0 } else { ($mx - $mn) / $mx }
    $t = [Math]::Min(1.0, [Math]::Max(0.0, ($sat - 0.20) / 0.25))              # 1 = orange body, 0 = white glyph
    $v = $pal.vMin + ($pal.vMax - $pal.vMin) * (($val - 0.75) / 0.2)
    $v = [Math]::Min($pal.vMax, [Math]::Max($pal.vMin, $v))
    $rgb = ConvertFrom-Hsv $pal.hue $pal.sat $v
    $R = [int]($gl.R + ($rgb[0] * 255 - $gl.R) * $t); $G = [int]($gl.G + ($rgb[1] * 255 - $gl.G) * $t); $B = [int]($gl.B + ($rgb[2] * 255 - $gl.B) * $t)
    $out.SetPixel($x, $y, [Drawing.Color]::FromArgb($p.A, $R, $G, $B))
  } }
  $out
}

function Get-IcoImage($bmp, $z) {   # classic 32-bit DIB entry (the taskbar/shell render these reliably); 256px uses PNG
  $b = New-Object Drawing.Bitmap $z, $z; $g = [Drawing.Graphics]::FromImage($b)
  $g.InterpolationMode = 'HighQualityBicubic'; $g.DrawImage($bmp, 0, 0, $z, $z); $g.Dispose()
  $ms = New-Object IO.MemoryStream
  if ($z -ge 256) { $b.Save($ms, [Drawing.Imaging.ImageFormat]::Png); return , $ms.ToArray() }
  $w = New-Object IO.BinaryWriter $ms
  $maskRow = [int]([Math]::Ceiling($z / 32.0) * 4)
  $w.Write([uint32]40); $w.Write([int32]$z); $w.Write([int32]($z * 2)); $w.Write([uint16]1); $w.Write([uint16]32)
  $w.Write([uint32]0); $w.Write([uint32]($z * $z * 4 + $maskRow * $z)); $w.Write([int32]0); $w.Write([int32]0); $w.Write([uint32]0); $w.Write([uint32]0)
  for ($y = $z - 1; $y -ge 0; $y--) { for ($x = 0; $x -lt $z; $x++) {
    $c = $b.GetPixel($x, $y); $w.Write([byte]$c.B); $w.Write([byte]$c.G); $w.Write([byte]$c.R); $w.Write([byte]$c.A) } }
  $w.Write((New-Object byte[] ($maskRow * $z)))
  $w.Flush(); , $ms.ToArray()
}

function Save-Ico($bmp, $path) {
  $sizes = 16, 24, 32, 48, 64, 128, 256
  $imgs = foreach ($z in $sizes) { , @($z, (Get-IcoImage $bmp $z)) }
  New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
  $fs = [IO.File]::Create($path); $w = New-Object IO.BinaryWriter $fs
  $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$imgs.Count)
  $off = 6 + 16 * $imgs.Count
  foreach ($i in $imgs) { $z = $i[0]; $w.Write([byte]($z % 256)); $w.Write([byte]($z % 256)); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$i[1].Length); $w.Write([uint32]$off); $off += $i[1].Length }
  foreach ($i in $imgs) { $w.Write([byte[]]$i[1]) }
  $w.Close(); $fs.Close()
}
