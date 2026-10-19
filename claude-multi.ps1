<#
.SYNOPSIS  Run the official Claude Desktop and any number of cc-switch-driven copies side by side (Windows).
.EXAMPLE   .\claude-multi.ps1 gui
.EXAMPLE   .\claude-multi.ps1 install
.EXAMPLE   .\claude-multi.ps1 add -Id gem -Name "Claude Gemini" -Palette gemini [-Provider <cc-switch provider id>]
.EXAMPLE   .\claude-multi.ps1 launch -Id 3p
#>
param(
  [Parameter(Position = 0)][ValidateSet('gui', 'install', 'launch', 'restart', 'route', 'agent', 'sync', 'list', 'add', 'remove', 'init', 'setup', 'uninstall', 'icons', 'providers')][string]$Command = 'gui',
  [string]$Id, [string]$Name, [string]$Kind, [string]$Palette = 'violet', [string]$Provider, [string]$Profile, [string]$Url, [string]$Proxy, [string]$Timezone,
  [switch]$Force
)
$Root = $PSScriptRoot
. (Join-Path $Root 'src\Core.ps1')

switch ($Command) {
  'gui'     {
    . (Join-Path $Root 'src\Gui.ps1')
    try { Show-Manager } catch {
      New-Item -ItemType Directory -Force $HomeRoot | Out-Null; Add-Content (Join-Path $HomeRoot 'gui-error.log') ("{0} {1}`n{2}" -f (Get-Date -Format s), $_, $_.ScriptStackTrace)
      Add-Type -AssemblyName System.Windows.Forms; [void][Windows.Forms.MessageBox]::Show("The manager window hit an error:`n`n$($_.Exception.Message)`n`nDetails: $HomeRoot\gui-error.log")
    }
  }
  'install' { Install-All -Force:$Force; "`nDone. Right-click a Desktop shortcut -> 'Pin to taskbar' (Windows does not let scripts pin)." }
  'launch'  { Invoke-Launch (Get-Instance $Id) -Show }
  'route'   { Invoke-RouteUrl $Url }
  'restart' {
    if ($Url -match '^claudemulti://restart/([A-Za-z0-9_-]+)$') { $Id = $Matches[1] }
    if (-not $Id) { throw 'restart needs -Id <instance>' }
    Restart-Instance (Get-Instance $Id) $null
  }
  'agent'   { Invoke-Agent }
  'sync'    { Backup-Sessions; Initialize-SessionStores; "copied: $(Invoke-SessionSync)" }
  'icons'   { Update-Icons (Read-Config).instances -Force:$Force }
  'providers' { Get-CcProviders | Select-Object id, name, current | Format-Table -AutoSize }
  'list' {
    $all = @((Read-Config).instances)
    $rows = foreach ($i in $all) {
      [pscustomobject]@{ Id = $i.id; Name = $i.name; Kind = $i.kind; Palette = $i.palette; Provider = $i.provider; DataDir = (Get-DataDir $i); Running = (@(Get-Roots $i | ForEach-Object ProcessId) -join ',') }
    }
    $rows | Format-Table -AutoSize
  }
  'add' {
    if (-not $Id -or $Id -notmatch '^[A-Za-z0-9_-]+$') { throw '-Id is required (letters, digits, - _)' }
    $cfg = Read-Config
    if ($cfg.instances | Where-Object id -eq $Id) { throw "Instance '$Id' already exists" }
    $k = if ($Kind) { $Kind } else { 'cc-switch' }
    $new = [ordered]@{ id = $Id; name = $(if ($Name) { $Name } else { "Claude $Id" }); kind = $k; palette = $Palette }
    if ($Provider) { $new.provider = $Provider }
    if ($Profile)  { $new.profile = $Profile }
    if ($Proxy)    { $new.proxy = $Proxy }
    if ($Timezone) { $new.timezone = $Timezone }
    $cfg.instances = @($cfg.instances) + [pscustomobject]$new
    Save-Config $cfg
    $envInfo = Initialize-InstanceEnv (Get-Instance $Id)
    "Added '$Id' ($k) and initialized environment:`nDataDir: $($envInfo.DataDir)`nShortcut: $($envInfo.DesktopShortcut)"
  }
  { $_ -in 'init', 'setup' } {
    $cfg = Read-Config
    $targets = if ($Id) { @(Get-Instance $Id) } else { @($cfg.instances) }
    $res = foreach ($i in $targets) { Initialize-InstanceEnv $i }
    $res | Format-Table -AutoSize
  }
  'remove' {
    $cfg = Read-Config; $i = $cfg.instances | Where-Object id -eq $Id
    if (-not $i) { throw "No instance '$Id'" }
    if ($i.id -eq 'official') { throw 'The primary official instance cannot be removed (use uninstall).' }
    $lnk = Get-DesktopLink $i
    if (Test-Path $lnk) { Remove-Item $lnk }
    $cfg.instances = @($cfg.instances | Where-Object id -ne $Id); Save-Config $cfg
    "removed '$Id' (its data dir $(Get-DataDir $i) was left untouched)"
  }
  'uninstall' {
    foreach ($i in (Read-Config).instances) {
      if ($i.kind -eq 'official') {   # point the official shortcuts back at the packaged app
        $ws = New-Object -ComObject WScript.Shell
        foreach ($l in @(Get-OfficialLinks | Where-Object { Test-Path $_ })) {
          $s = $ws.CreateShortcut($l); $s.TargetPath = "$env:WINDIR\explorer.exe"
          $s.Arguments = "shell:AppsFolder\$OfficialAumid"; $s.IconLocation = ''; $s.Save()
          [ShellProp]::SetLinkAumid($l, $OfficialAumid); "restored: $l"
        }
      } else {
        $lnk = Get-DesktopLink $i
        if (Test-Path $lnk) { Remove-Item $lnk; "removed: $lnk" }
      }
    }
    $k = 'HKCU:\Software\Classes\claude\shell\open\command'
    if (Test-Path $k) { Set-ItemProperty $k -Name '(default)' -Value "`"$((Get-ClaudePackage).InstallLocation)\app\Claude.exe`" `"%1`""; 'restored: claude:// handler' }
  }
}
