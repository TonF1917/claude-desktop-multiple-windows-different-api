<#
.SYNOPSIS
Read-only post-upgrade audit for Claude Multi on Windows (MSIX install).

.DESCRIPTION
Compares the installed package's Claude.exe absolute path against the per-instance
UDP firewall rules, and checks each instance's shield.cjs probe timeout against
the generator template in src/Core.ps1.

This script NEVER writes to the system: it does not install firewall rules, does
not restart instances, does not trigger an app update, and does not modify any
Data directory. Run it directly (do not dot-source); it exits with a status code.

Exit codes:
  0  all checks OK
  1  drift detected (STALE / MISSING / DRIFT) - human action required
  2  environment error (package / config / firewall query unavailable)

Remediation for STALE rules (requires elevation):
  .\claude-multi.ps1 udp-guard
#>
[CmdletBinding()]
param(
  [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
  [string]$HomeRoot = (Join-Path $env:USERPROFILE '.claude-multi')
)

$ErrorActionPreference = 'Stop'
$problems = 0

function Get-ExpectedExe {
  $pkg = Get-AppxPackage AnthropicPBC.Claude |
         Sort-Object Version -Descending | Select-Object -First 1
  if (-not $pkg) { throw 'MSIX package AnthropicPBC.Claude not found' }
  $exe = Join-Path $pkg.InstallLocation 'app\Claude.exe'
  if (-not (Test-Path -LiteralPath $exe)) { throw "package exe missing: $exe" }
  [pscustomobject]@{ Version = [string]$pkg.Version; Exe = $exe }
}

function Get-InstanceIds {
  $cfgPath = Join-Path $RepoRoot 'instances.json'
  if (-not (Test-Path -LiteralPath $cfgPath)) { throw "config missing: $cfgPath" }
  $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
  @($cfg.instances | Where-Object {
      $_.PSObject.Properties['proxy'] -and $_.proxy
    } | ForEach-Object { [string]$_.id })
}

function Get-DataDirFor([string]$id) {
  if ($id -eq 'official') { return (Join-Path $env:APPDATA 'Claude') }
  Join-Path $HomeRoot "$id\Data"
}

function Get-MaxTimeFrom([string]$content) {
  $m = [regex]::Match($content, "--max-time', '(\d+)'")
  if ($m.Success) { return $m.Groups[1].Value }
  ''
}

function Get-PkgTagFrom([string]$path) {
  if ($path -match 'AnthropicPBC\.Claude_([^\\]+)') { return $matches[1] }
  '(none)'
}

try {
  $pkg = Get-ExpectedExe
  $ids = Get-InstanceIds
  $corePath = Join-Path $RepoRoot 'src\Core.ps1'
  $templateMax = if (Test-Path -LiteralPath $corePath) {
    Get-MaxTimeFrom (Get-Content -LiteralPath $corePath -Raw)
  } else { '' }
} catch {
  Write-Output "[ERROR] environment: $($_.Exception.Message)"
  exit 2
}

Write-Output "package version : $($pkg.Version)"
Write-Output "expected exe    : $($pkg.Exe)"
Write-Output "template timeout: $(if ($templateMax) { $templateMax + 's' } else { 'not found in Core.ps1' })"
Write-Output ('-' * 78)

$rows = @()
foreach ($id in $ids) {
  $ruleName = "Claude Multi - block outbound UDP ($id)"
  $rule = $null
  $program = ''
  try {
    $rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue |
            Select-Object -First 1
    if ($rule) {
      $f = $rule | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue
      if ($f) { $program = [string]$f.Program }
    }
  } catch {
    Write-Output "[ERROR] firewall query failed for $id : $($_.Exception.Message)"
    exit 2
  }

  $enabled = if ($rule) { [string]$rule.Enabled } else { '-' }
  $state = 'STALE'
  if (-not $rule) { $state = 'MISSING' }
  elseif ($enabled -ne 'True') { $state = 'DISABLED' }
  elseif ($program -and ($program -ieq $pkg.Exe)) { $state = 'OK' }
  if ($state -ne 'OK') { $problems++ }

  $data = Get-DataDirFor $id
  $shield = Join-Path $data 'shield.cjs'
  $shieldState = 'MISSING'
  $shieldMax = ''
  if (Test-Path -LiteralPath $shield) {
    $shieldMax = Get-MaxTimeFrom (Get-Content -LiteralPath $shield -Raw)
    if (-not $templateMax) { $shieldState = 'NO-TEMPLATE' }
    elseif ($shieldMax -eq $templateMax) { $shieldState = 'OK' }
    else { $shieldState = 'DRIFT' }
  }
  if ($shieldState -ne 'OK') { $problems++ }

  $rows += [pscustomobject]@{
    Id       = $id
    Rule     = $state
    Enabled  = $enabled
    RuleVer  = Get-PkgTagFrom $program
    Shield   = $shieldState
    ShieldMs = $shieldMax
  }
}

Write-Output ('{0,-10} {1,-9} {2,-8} {3,-34} {4,-11} {5}' -f 'ID', 'RULE', 'ENABLED', 'RULE PKG TAG', 'SHIELD', 'PROBE')
foreach ($r in $rows) {
  Write-Output ('{0,-10} {1,-9} {2,-8} {3,-34} {4,-11} {5}s' -f $r.Id, $r.Rule, $r.Enabled, $r.RuleVer, $r.Shield, $r.ShieldMs)
}
Write-Output ('-' * 78)

if ($problems -gt 0) {
  Write-Output "RESULT: $problems check(s) need attention."
  Write-Output "If Rule is STALE/MISSING, run '.\claude-multi.ps1 udp-guard' in an ELEVATED shell after upgrading."
  Write-Output "If Shield is DRIFT, restart the instance via '.\claude-multi.ps1 restart -Id <id>' so Core.ps1 rewrites it."
  exit 1
}
Write-Output 'RESULT: all checks OK.'
exit 0
