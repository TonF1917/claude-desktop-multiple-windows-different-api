# WinForms manager in the Anthropic look (ivory / slate / clay, serif type): how many windows, which API and colour each one uses.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
if (-not ('Win32.Dpi' -as [type])) { Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' -Name Dpi -Namespace Win32 }

function Show-Manager {
  [void][Win32.Dpi]::SetProcessDPIAware()
  [Windows.Forms.Application]::EnableVisualStyles()
  $zh = ((Read-Config).settings.language -eq 'zh')
  function L($zhText, $enText) { if ($zh) { $zhText } else { $enText } }
  function C($hex) { [Drawing.ColorTranslator]::FromHtml($hex) }

  # ---- Anthropic palette
  $IVORY = C '#FAF9F5'; $SLATE = C '#141413'; $CLAY = C '#D97757'; $CLAY_D = C '#C6613F'; $OAT = C '#E8E6DC'; $CLOUD = C '#F0EEE6'
  $MID = C '#5E5D59'; $GRAY = C '#87867F'; $SEL = C '#F6E7DF'

  $fams = (New-Object Drawing.Text.InstalledFontCollection).Families.Name
  $fam = (@('Noto Serif SC', 'Source Han Serif SC', '思源宋体', 'Georgia', 'SimSun') | Where-Object { $fams -contains $_ } | Select-Object -First 1)
  if (-not $fam) { $fam = 'Times New Roman' }
  $fBody = New-Object Drawing.Font($fam, 10); $fSmall = New-Object Drawing.Font($fam, 9)
  $fTitle = New-Object Drawing.Font($fam, 21, [Drawing.FontStyle]::Bold); $fHead = New-Object Drawing.Font($fam, 12, [Drawing.FontStyle]::Bold)

  $cfg = Read-Config
  $pal = Get-Palettes
  $palNames = @($pal.PSObject.Properties.Name)
  $providers = @(Get-CcProviders)
  $snapshot = @{}; foreach ($i in $cfg.instances) { $snapshot[$i.id] = [string]$i.palette }
  $script:baseBmp = $null; $iconCache = @{}

  function Get-RoundPath($w, $h, $r) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath; $d = $r * 2
    $p.AddArc(0, 0, $d, $d, 180, 90); $p.AddArc($w - $d - 1, 0, $d, $d, 270, 90)
    $p.AddArc($w - $d - 1, $h - $d - 1, $d, $d, 0, 90); $p.AddArc(0, $h - $d - 1, $d, $d, 90, 90); $p.CloseFigure(); $p
  }
  function New-Card($x, $y, $w, $h) {
    $p = New-Object Windows.Forms.Panel; $p.Location = New-Object Drawing.Point($x, $y); $p.Size = New-Object Drawing.Size($w, $h); $p.BackColor = [Drawing.Color]::White
    $p.Add_Paint({ param($s, $e)
      $e.Graphics.SmoothingMode = 'AntiAlias'; $path = Get-RoundPath $s.Width $s.Height 12
      $pen = New-Object Drawing.Pen($OAT, 1.5); $e.Graphics.DrawPath($pen, $path); $pen.Dispose() })
    $p.Region = New-Object Drawing.Region (Get-RoundPath $w $h 12)
    $p
  }
  function New-Btn($text, $x, $y, $w, $primary, $handler) {
    $b = New-Object Windows.Forms.Button; $b.Text = $text; $b.Location = New-Object Drawing.Point($x, $y); $b.Size = New-Object Drawing.Size($w, 40)
    $b.FlatStyle = 'Flat'; $b.Font = $fBody; $b.Cursor = 'Hand'; $b.FlatAppearance.BorderSize = 0
    if ($primary) { $b.BackColor = $CLAY; $b.ForeColor = [Drawing.Color]::White; $b.FlatAppearance.MouseOverBackColor = $CLAY_D; $b.FlatAppearance.MouseDownBackColor = $CLAY_D }
    else {
      $b.BackColor = [Drawing.Color]::White; $b.ForeColor = $SLATE; $b.FlatAppearance.MouseOverBackColor = $CLOUD; $b.FlatAppearance.MouseDownBackColor = $CLOUD
      $b.Add_Paint({ param($s, $e)
        $e.Graphics.SmoothingMode = 'AntiAlias'; $path = Get-RoundPath $s.Width $s.Height 10
        $pen = New-Object Drawing.Pen($OAT, 2); $e.Graphics.DrawPath($pen, $path); $pen.Dispose() })
    }
    $b.Region = New-Object Drawing.Region (Get-RoundPath $b.Width $b.Height 10)
    $b.Add_Click($handler); $b
  }
  function New-Label($text, $x, $y, $w, $h, $font, $color) {
    $l = New-Object Windows.Forms.Label; $l.Text = $text; $l.Location = New-Object Drawing.Point($x, $y); $l.Size = New-Object Drawing.Size($w, $h)
    $l.Font = $font; $l.ForeColor = $color; $l.BackColor = [Drawing.Color]::Transparent; $l
  }
  function New-Check($text, $x, $y, $w, $checked) {
    $c = New-Object Windows.Forms.CheckBox; $c.Text = $text; $c.Location = New-Object Drawing.Point($x, $y); $c.Size = New-Object Drawing.Size($w, 30)
    $c.Font = $fBody; $c.ForeColor = $SLATE; $c.BackColor = [Drawing.Color]::White; $c.FlatStyle = 'Flat'; $c.Checked = $checked; $c.Cursor = 'Hand'; $c
  }

  $form = New-Object Windows.Forms.Form
  $form.Text = L 'Claude 多窗口管理器' 'Claude Multi-Window Manager'
  $form.Font = $fBody; $form.BackColor = $IVORY; $form.ForeColor = $SLATE; $form.StartPosition = 'CenterScreen'
  $form.ClientSize = New-Object Drawing.Size(1240, 860); $form.MinimumSize = New-Object Drawing.Size(1240, 860); $form.MaximizeBox = $false
  $form.FormBorderStyle = 'FixedSingle'

  # ---- header: clay burst + serif title
  $burst = New-Object Windows.Forms.Panel; $burst.Location = New-Object Drawing.Point(28, 22); $burst.Size = New-Object Drawing.Size(46, 46); $burst.BackColor = $IVORY
  $burst.Add_Paint({ param($s, $e)
    $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'; $pen = New-Object Drawing.Pen($CLAY, 3.2); $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    for ($k = 0; $k -lt 12; $k++) { $a = $k * [Math]::PI / 6; $r1 = 6; $r2 = if ($k % 2) { 17 } else { 21 }
      $g.DrawLine($pen, [single](23 + [Math]::Cos($a) * $r1), [single](23 + [Math]::Sin($a) * $r1), [single](23 + [Math]::Cos($a) * $r2), [single](23 + [Math]::Sin($a) * $r2)) } })
  $lblTitle = New-Label (L 'Claude 多窗口管理器' 'Multiple windows, different APIs') 86 8 820 66 $fTitle $SLATE
  $lblSub = New-Label (L '官方订阅与第三方 API 同时运行,每个窗口独立图标、独立任务栏按钮' 'Official subscription and third-party APIs side by side, one icon and taskbar button each') 90 76 860 28 $fSmall $MID
  $lblLang = New-Label 'Language / 语言' 930 28 170 26 $fSmall $GRAY
  $lblStatus = New-Label '' 90 104 1000 24 $fSmall $GRAY
  function Set-Status($text) { $lblStatus.Text = ('{0}  -  {1}' -f (Get-Date -Format 'HH:mm:ss'), $text) }
  $cmbLang = New-Object Windows.Forms.ComboBox; $cmbLang.DropDownStyle = 'DropDownList'; $cmbLang.Location = New-Object Drawing.Point(1100, 22); $cmbLang.Size = New-Object Drawing.Size(112, 28); $cmbLang.Font = $fSmall; $cmbLang.FlatStyle = 'Flat'
  [void]$cmbLang.Items.Add('English'); [void]$cmbLang.Items.Add('中文'); $cmbLang.SelectedIndex = $(if ($zh) { 1 } else { 0 }); $cmbLang.TabStop = $false
  $cmbLang.Add_SelectionChangeCommitted({
    $c = Read-Config; $c.settings.language = $(if ($cmbLang.SelectedIndex -eq 1) { 'zh' } else { 'en' }); Save-Config $c
    Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-STA', '-File', "`"$Root\claude-multi.ps1`"", 'gui'
    $form.Close() })

  # ---- windows table card
  $cardGrid = New-Card 24 108 850 470
  $lblGrid = New-Label (L '窗口' 'Windows') 20 10 300 34 $fHead $SLATE
  $grid = New-Object Windows.Forms.DataGridView
  $grid.Location = New-Object Drawing.Point(14, 54); $grid.Size = New-Object Drawing.Size(822, 404)
  $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false; $grid.RowHeadersVisible = $false; $grid.SelectionMode = 'FullRowSelect'; $grid.MultiSelect = $false
  $grid.AutoSizeColumnsMode = 'Fill'; $grid.BackgroundColor = [Drawing.Color]::White; $grid.BorderStyle = 'None'; $grid.CellBorderStyle = 'SingleHorizontal'; $grid.GridColor = $CLOUD
  $grid.RowTemplate.Height = 42; $grid.EditMode = 'EditOnKeystrokeOrF2'; $grid.EnableHeadersVisualStyles = $false
  $grid.ColumnHeadersHeightSizeMode = 'DisableResizing'; $grid.ColumnHeadersHeight = 40; $grid.ColumnHeadersBorderStyle = 'None'
  $grid.ColumnHeadersDefaultCellStyle.BackColor = [Drawing.Color]::White; $grid.ColumnHeadersDefaultCellStyle.ForeColor = $GRAY; $grid.ColumnHeadersDefaultCellStyle.Font = $fSmall
  $grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = [Drawing.Color]::White; $grid.ColumnHeadersDefaultCellStyle.SelectionForeColor = $GRAY
  $grid.DefaultCellStyle.BackColor = [Drawing.Color]::White; $grid.DefaultCellStyle.ForeColor = $SLATE; $grid.DefaultCellStyle.SelectionBackColor = $SEL; $grid.DefaultCellStyle.SelectionForeColor = $SLATE
  $cName = New-Object Windows.Forms.DataGridViewTextBoxColumn; $cName.HeaderText = L '名称' 'Name'; $cName.Name = 'name'; $cName.FillWeight = 22
  $cId = New-Object Windows.Forms.DataGridViewTextBoxColumn; $cId.HeaderText = 'ID'; $cId.Name = 'id'; $cId.ReadOnly = $true; $cId.FillWeight = 10
  $cProv = New-Object Windows.Forms.DataGridViewTextBoxColumn; $cProv.ReadOnly = $true; $cProv.HeaderText = L '接口 / 供应商' 'API / provider'; $cProv.Name = 'provider'; $cProv.FillWeight = 34
  $provText = [ordered]@{ '__official' = (L '官方订阅' 'Official subscription'); '' = (L '跟随 cc-switch 当前选择' 'Follow cc-switch selection') }
  $provFmt = @{}
  foreach ($p in $providers) {
    $fmt = [string]$p.meta.apiFormat; $provFmt[[string]$p.id] = $fmt
    $suffix = if ($fmt -and $fmt -ne 'anthropic') { L '  (需经 cc-switch 网关)' '  (needs the cc-switch gateway)' } else { L '  (直连上游)' '  (direct)' }
    $provText[[string]$p.id] = ($p.name + $suffix)
  }
  function Get-ProvId([string]$text) { foreach ($k in $provText.Keys) { if ($provText[$k] -eq $text) { return [string]$k } }; '' }
  $cPal = New-Object Windows.Forms.DataGridViewTextBoxColumn; $cPal.HeaderText = L '配色(点击更改)' 'Colour (click)'; $cPal.Name = 'palette'; $cPal.ReadOnly = $true; $cPal.FillWeight = 18
  $cStat = New-Object Windows.Forms.DataGridViewTextBoxColumn; $cStat.HeaderText = L '状态' 'Status'; $cStat.Name = 'status'; $cStat.ReadOnly = $true; $cStat.FillWeight = 14
  foreach ($col in @($cName, $cId, $cProv, $cPal, $cStat)) { [void]$grid.Columns.Add($col) }

  function Get-Swatch($spec) {
    if ($spec -eq 'official') { return (C '#D97757') }
    $p = Resolve-Palette $spec $pal; $v = ($p.vMin + $p.vMax) / 2; $rgb = ConvertFrom-Hsv $p.hue $p.sat $v
    [Drawing.Color]::FromArgb([int]($rgb[0] * 255), [int]($rgb[1] * 255), [int]($rgb[2] * 255))
  }
  function Set-PaletteCell($row, $spec) {
    $row.Cells['palette'].Value = $spec
    $c = Get-Swatch $spec
    $row.Cells['palette'].Style.BackColor = $c; $row.Cells['palette'].Style.SelectionBackColor = $c
    $lum = 0.3 * $c.R + 0.59 * $c.G + 0.11 * $c.B; $fc = if ($lum -gt 150) { $SLATE } else { [Drawing.Color]::White }
    $row.Cells['palette'].Style.ForeColor = $fc; $row.Cells['palette'].Style.SelectionForeColor = $fc
  }
  function Add-InstanceRow($i) {
    $idx = $grid.Rows.Add(); $r = $grid.Rows[$idx]
    $r.Cells['name'].Value = $i.name; $r.Cells['id'].Value = $i.id
    if ($i.kind -eq 'official') {
      $r.Cells['provider'].Value = $provText['__official']; $r.Cells['provider'].ReadOnly = $true; Set-PaletteCell $r 'official'
    } else {
      $pid_ = $(if ($i.provider -and $provText.Contains([string]$i.provider)) { [string]$i.provider } else { '' })
      $r.Cells['provider'].Value = $provText[$pid_]; Set-PaletteCell $r ([string]$i.palette)
    }
  }
  foreach ($i in $cfg.instances) { Add-InstanceRow $i }
  $grid.Add_DataError({ param($s, $e) $e.ThrowException = $false })
  foreach ($ctl in @($lblGrid, $grid)) { $cardGrid.Controls.Add($ctl) }

  # ---- icon preview card + actions
  $cardSide = New-Card 894 108 322 470
  $pic = New-Object Windows.Forms.PictureBox; $pic.Location = New-Object Drawing.Point(20, 18); $pic.Size = New-Object Drawing.Size(96, 96); $pic.SizeMode = 'Zoom'; $pic.BackColor = [Drawing.Color]::White
  $lblPrev = New-Label (L '图标预览' 'Icon preview') 128 20 180 34 $fHead $SLATE
  $lblPrev2 = New-Label (L '用于桌面、任务栏、系统托盘' 'Desktop, taskbar and tray') 128 58 188 56 $fSmall $GRAY
  function Show-Preview {
    if ($grid.CurrentRow -eq $null) { return }
    $spec = [string]$grid.CurrentRow.Cells['palette'].Value
    if (-not $iconCache.ContainsKey($spec)) {
      $form.Cursor = 'WaitCursor'
      if (-not $script:baseBmp) { $script:baseBmp = Get-IconBase (Get-ClaudePackage) }
      $iconCache[$spec] = if ($spec -eq 'official') { $script:baseBmp } else { Convert-IconBase $script:baseBmp (Resolve-Palette $spec $pal) }
      $form.Cursor = 'Default'
    }
    $pic.Image = $iconCache[$spec]
  }
  $grid.Add_SelectionChanged({ Show-Preview })

  $menu = New-Object Windows.Forms.ContextMenuStrip; $menu.Font = $fBody
  $script:pickRow = $null; $script:pickMode = ''
  function Show-Err($ex) {
    try { New-Item -ItemType Directory -Force $HomeRoot | Out-Null; Add-Content (Join-Path $HomeRoot 'gui-error.log') ("{0} {1}" -f (Get-Date -Format s), $ex) } catch { }
    [void][Windows.Forms.MessageBox]::Show(("{0}`n`n{1}" -f (L '操作失败(详情已写入 ~\.claude-multi\gui-error.log):' 'Action failed (details in ~\.claude-multi\gui-error.log):'), $ex.Exception.Message))
  }
  $grid.Add_CellClick({
    param($s, $e)
    try {
      if ($e.RowIndex -lt 0) { return }
      $row = $grid.Rows[$e.RowIndex]; $col = $grid.Columns[$e.ColumnIndex].Name
      $instId = [string]$row.Cells['id'].Value; $instKind = [string]$row.Cells['kind'].Value
      if ($col -eq 'name') { [void]$grid.BeginEdit($false); return }
      if ($col -eq 'provider' -and $instKind -eq 'official') { return }
      if ($instId -eq 'official' -and $col -ne 'name') { return }
      if ($col -ne 'provider' -and $col -ne 'palette') { return }
      $script:pickRow = $row; $script:pickMode = $col; $menu.Items.Clear()
      if ($col -eq 'provider') {
        foreach ($k in $provText.Keys) { if ($k -eq '__official') { continue }; $it = $menu.Items.Add([string]$provText[$k]); $it.Tag = [string]$k }
      } else {
        foreach ($n in $palNames) { $it = $menu.Items.Add($n); $it.Tag = $n; $bm = New-Object Drawing.Bitmap 14, 14; $g = [Drawing.Graphics]::FromImage($bm); $g.Clear((Get-Swatch $n)); $g.Dispose(); $it.Image = $bm }
        $cu = $menu.Items.Add((L '自定义颜色…' 'Custom colour...')); $cu.Tag = '*custom'
      }
      $menu.Show($grid, $grid.PointToClient([Windows.Forms.Cursor]::Position))
    } catch { Show-Err $_ } })
  $menu.Add_ItemClicked({
    param($s, $e)
    try {
      $tag = [string]$e.ClickedItem.Tag
      if ($script:pickMode -eq 'provider') {
        if ($tag -and $provFmt[$tag] -and $provFmt[$tag] -ne 'anthropic') {
          [void][Windows.Forms.MessageBox]::Show((L '该供应商使用非 Anthropic 接口,必须经 cc-switch 网关,不能直连。' 'This provider is not Anthropic-format and must go through the cc-switch gateway; it cannot be used directly.'))
          return
        }
        $script:pickRow.Cells['provider'].Value = $provText[$tag]
      } else {
        if ($tag -eq '*custom') { $dlg = New-Object Windows.Forms.ColorDialog; $dlg.FullOpen = $true; if ($dlg.ShowDialog() -ne 'OK') { return }; $tag = '#{0:X2}{1:X2}{2:X2}' -f $dlg.Color.R, $dlg.Color.G, $dlg.Color.B }
        Set-PaletteCell $script:pickRow $tag; Show-Preview
      }
    } catch { Show-Err $_ } })

  function Read-GridConfig {
    [void]$grid.EndEdit(); [void]$grid.CommitEdit('CurrentCellChange')
    $c = Read-Config
    foreach ($row in $grid.Rows) {
      $i = $c.instances | Where-Object id -eq ([string]$row.Cells['id'].Value); if (-not $i) { continue }
      Set-Prop $i 'name' ([string]$row.Cells['name'].Value)
      if ($i.id -ne 'official') {
        Set-Prop $i 'palette' ([string]$row.Cells['palette'].Value)
        if ($i.kind -ne 'official') {
          $pv = Get-ProvId ([string]$row.Cells['provider'].Value)
          if ($pv) { Set-Prop $i 'provider' $pv } elseif ($i.PSObject.Properties['provider']) { $i.PSObject.Properties.Remove('provider') }
        }
      }
    }
    $c.settings.syncSessions = $chkSync.Checked; $c.settings.syncSettings = $chkSet.Checked
    $c.settings.liveRefresh = $chkLive.Checked; $c.settings.refreshOfficial = $chkOff.Checked; $c.settings.notifyReload = $chkNote.Checked
    $c.settings.protocol = $(if ($cmbProto.SelectedIndex -ge 0 -and $cmbProto.SelectedIndex -lt $protoIds.Count) { $protoIds[$cmbProto.SelectedIndex] } else { 'last' })
    $c
  }

  $numAdd = New-Object Windows.Forms.NumericUpDown; $numAdd.Location = New-Object Drawing.Point(20, 134); $numAdd.Size = New-Object Drawing.Size(62, 28); $numAdd.Minimum = 1; $numAdd.Maximum = 20; $numAdd.Value = 1; $numAdd.Font = $fBody
  $btnAdd = New-Btn (L '添加窗口' 'Add windows') 92 128 210 $false {
    $c = Read-Config
    for ($k = 0; $k -lt [int]$numAdd.Value; $k++) {
      $n = 2; while ($c.instances | Where-Object id -eq "x$n") { $n++ }
      $used = @($c.instances | ForEach-Object { [string]$_.palette })
      $p = ($palNames | Where-Object { $used -notcontains $_ } | Select-Object -First 1); if (-not $p) { $p = $palNames[$n % $palNames.Count] }
      $new = [pscustomobject]@{ id = "x$n"; name = "Claude 3P $n"; kind = 'cc-switch'; palette = $p }
      $c.instances = @($c.instances) + $new; Add-InstanceRow $new; Save-Config $c
    } }
  $btnRemove = New-Btn (L '删除所选' 'Remove selected') 20 172 282 $false {
    $r = $grid.CurrentRow; if (-not $r) { return }
    $id = [string]$r.Cells['id'].Value
    if ($id -eq 'official') { [void][Windows.Forms.MessageBox]::Show((L '官方窗口不能删除。' 'The official window cannot be removed.')); return }
    $c = Read-Config; $c.instances = @($c.instances | Where-Object id -ne $id); Save-Config $c
    $lnk = Get-DesktopLink ([pscustomobject]@{ name = [string]$r.Cells['name'].Value }); if (Test-Path $lnk) { Remove-Item $lnk }
    $grid.Rows.Remove($r) }
  $btnApply = New-Btn (L '应用更改' 'Apply changes') 20 216 282 $false {
    $form.Cursor = 'WaitCursor'; $c = Read-GridConfig
    foreach ($i in $c.instances) { if ($snapshot[$i.id] -ne [string]$i.palette) { Remove-Item (Get-IconPath $i) -ErrorAction SilentlyContinue; $snapshot[$i.id] = [string]$i.palette } }
    Save-Config $c; Install-All | Out-Null; $form.Cursor = 'Default'
    Set-Status (L '已应用。新快捷方式在桌面,右键即可固定到任务栏。' 'Applied. New shortcuts are on the Desktop - right-click to pin them to the taskbar.') }
  $btnRestart = New-Btn (L '重启所选(载入新会话)' 'Restart selected (reload sessions)') 20 260 282 $false {
    $r = $grid.CurrentRow; if (-not $r) { return }
    $inst = Get-Instance ([string]$r.Cells['id'].Value)
    if (-not @(Get-Roots $inst)) { [void][Windows.Forms.MessageBox]::Show((L '该窗口没有在运行。' 'That window is not running.')); return }
    if ([Windows.Forms.MessageBox]::Show((L '将重启该窗口以载入其他窗口的新会话/固定项。窗口里未发送的草稿会丢失。继续?' 'This restarts the window so it loads new sessions and pins from the other windows. Unsent drafts in it are lost. Continue?'), '', 'YesNo') -ne 'Yes') { return }
    $form.Cursor = 'WaitCursor'; Save-Config (Read-GridConfig); Restart-Instance $inst $null; $form.Cursor = 'Default' }
  $btnLaunch = New-Btn (L '启动所选' 'Launch selected') 20 316 282 $true {
    $r = $grid.CurrentRow; if (-not $r) { return }
    Save-Config (Read-GridConfig); Invoke-Launch (Get-Instance ([string]$r.Cells['id'].Value)) -Show }
  $btnAll = New-Btn (L '全部启动' 'Launch all') 20 360 282 $false {
    Save-Config (Read-GridConfig); foreach ($i in (Read-Config).instances) { Invoke-Launch $i; Start-Sleep -Seconds 2 } }
  $btnSync = New-Btn (L '立即同步会话' 'Sync sessions now') 20 404 282 $false {
    $form.Cursor = 'WaitCursor'; Backup-Sessions; Initialize-SessionStores; $n = Invoke-SessionSync; $form.Cursor = 'Default'
    Set-Status (L "已同步 $n 个文件。" "Synced $n file(s).") }
  foreach ($ctl in @($pic, $lblPrev, $lblPrev2, $numAdd, $btnAdd, $btnRemove, $btnApply, $btnRestart, $btnLaunch, $btnAll, $btnSync)) { $cardSide.Controls.Add($ctl) }

  # ---- sync & behaviour card
  $cardSet = New-Card 24 594 1192 242
  $lblSet = New-Label (L '同步与行为' 'Sync and behaviour') 20 10 400 34 $fHead $SLATE
  $chkSync = New-Check (L '在各窗口间同步会话(后台)' 'Sync sessions across windows (background)') 18 48 1150 ([bool]$cfg.settings.syncSessions)
  $chkSet = New-Check (L '同步固定(置顶)/星标会话的顺序与 MCP 服务器' 'Sync pinned / starred sessions, pin order and MCP servers') 18 80 1150 ([bool]$cfg.settings.syncSettings)
  $chkLive = New-Check (L '实时刷新:空闲且不在前台的窗口会在后台静默重启以载入新会话(忙碌/正在使用的绝不打断)' 'Live refresh: idle, unfocused windows restart silently to load new sessions') 18 112 1150 ([bool]$cfg.settings.liveRefresh)
  $chkOff = New-Check (L '同时对官方窗口启用实时刷新(默认关闭:官方窗口里可能有未发送的草稿或正在运行的会话)' 'Also live-refresh the official window (off by default: may hold unsent drafts)') 18 144 1150 ([bool]$cfg.settings.refreshOfficial)
  $chkNote = New-Check (L '需要重载时弹出通知(默认关闭)' 'Show a notification when a window in use needs a reload (off by default)') 700 172 480 ([bool]$cfg.settings.notifyReload)
  $lblProto = New-Label (L 'claude:// 链接打开到:' 'Open claude:// links in:') 20 176 260 28 $fBody $SLATE
  $cmbProto = New-Object Windows.Forms.ComboBox; $cmbProto.DropDownStyle = 'DropDownList'; $cmbProto.Location = New-Object Drawing.Point(290, 172); $cmbProto.Size = New-Object Drawing.Size(360, 28); $cmbProto.Font = $fBody; $cmbProto.FlatStyle = 'Flat'
  $protoIds = @('last') + @($cfg.instances | ForEach-Object { [string]$_.id })
  [void]$cmbProto.Items.Add((L '最近使用的窗口' 'Last used window')); foreach ($i in $cfg.instances) { [void]$cmbProto.Items.Add([string]$i.name) }
  $cmbProto.SelectedIndex = [Math]::Max(0, [array]::IndexOf($protoIds, [string]$cfg.settings.protocol))
  $hintText = if ($providers.Count -eq 0) { L '未读取到 cc-switch 供应商;仍可使用“跟随 cc-switch”。' 'No cc-switch providers found; "Follow cc-switch" still works.' } else { L '“跟随”共用 cc-switch 网关;选具体供应商则该窗口直连其上游,可与其他窗口同时使用不同供应商。' '"Follow" uses the cc-switch gateway; a specific provider connects that window directly (a different API per window).' }
  $hint = New-Label $hintText 20 208 1150 26 $fSmall $GRAY
  foreach ($ctl in @($lblSet, $chkSync, $chkSet, $chkLive, $chkOff, $chkNote, $lblProto, $cmbProto, $hint)) { $cardSet.Controls.Add($ctl) }

  foreach ($ctl in @($burst, $lblTitle, $lblSub, $lblStatus, $lblLang, $cmbLang, $cardGrid, $cardSide, $cardSet)) { $form.Controls.Add($ctl) }

  # ---- live status
  $timer = New-Object Windows.Forms.Timer; $timer.Interval = 3000
  $timer.Add_Tick({
    try {
      $all = @((Read-Config).instances); $map = @{}
      foreach ($m in Get-ClaudeMains) { $x = Find-InstanceOf $m $all; if ($x) { $map[$x.id] = $m.ProcessId } }
      foreach ($row in $grid.Rows) { $id = [string]$row.Cells['id'].Value; $row.Cells['status'].Value = $(if ($map.ContainsKey($id)) { (L '运行中 ' 'running ') + $map[$id] } else { '' }) }
    } catch { } })
  $timer.Start()
  $form.Add_Shown({ Show-Preview })
  [void]$form.ShowDialog()
  $timer.Stop()
}
