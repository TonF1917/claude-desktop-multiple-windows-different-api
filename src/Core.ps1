# Shared logic for claude-multi (dot-sourced by claude-multi.ps1). Requires $Root to be set.
$ErrorActionPreference = 'Stop'
$script:RealLocal     = $env:LOCALAPPDATA                        # captured before any per-instance override
if (-not $Root) { $script:Root = Split-Path -Parent $PSScriptRoot }
$script:ConfigPath    = Join-Path $Root 'instances.json'
$script:HomeRoot      = Join-Path $env:USERPROFILE '.claude-multi'   # state, icons and one private fake %LOCALAPPDATA% per extra instance
$script:StateDir      = $HomeRoot                                  # NB: not under AppData\*\ClaudeMulti - Explorer cannot load icons from there
$script:IconDir       = Join-Path $StateDir 'icons'
$script:StatePath     = Join-Path $StateDir 'state.json'
$script:SourceDir     = Join-Path $RealLocal 'Claude-3p'         # where the app (and cc-switch) keep the 3P config library
$script:OfficialDir   = Join-Path $env:APPDATA 'Claude'
$script:OfficialAumid = 'AnthropicPBC.Claude_fnn82j28hfe8t!Claude'
$script:PinDir        = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
$script:Wscript       = Join-Path $env:WINDIR 'System32\wscript.exe'

. (Join-Path $Root 'src\Icon.ps1')
. (Join-Path $Root 'src\CcSwitch.ps1')
if (-not ('ShellProp' -as [type])) { Add-Type -TypeDefinition (Get-Content (Join-Path $Root 'src\ShellProp.cs') -Raw) -Language CSharp }
. (Join-Path $Root 'src\Extras.ps1')

# ---------------------------------------------------------------- config / state
function Write-Utf8($path, $text) { [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false)) }

$script:CountryNetworkMap = @{
  'US' = @{ timezone = 'America/New_York';   lang = 'en-US'; acceptLanguage = 'en-US,en;q=0.9' }
  'CA' = @{ timezone = 'America/Toronto';    lang = 'en-CA'; acceptLanguage = 'en-CA,en;q=0.9' }
  'GB' = @{ timezone = 'Europe/London';      lang = 'en-GB'; acceptLanguage = 'en-GB,en;q=0.9' }
  'SG' = @{ timezone = 'Asia/Singapore';     lang = 'en-SG'; acceptLanguage = 'en-SG,en;q=0.9' }
  'KR' = @{ timezone = 'Asia/Seoul';         lang = 'ko-KR'; acceptLanguage = 'ko-KR,ko;q=0.9,en-US;q=0.8,en;q=0.7' }
  'JP' = @{ timezone = 'Asia/Tokyo';         lang = 'ja-JP'; acceptLanguage = 'ja-JP,ja;q=0.9,en-US;q=0.8,en;q=0.7' }
  'DE' = @{ timezone = 'Europe/Berlin';      lang = 'de-DE'; acceptLanguage = 'de-DE,de;q=0.9,en-US;q=0.8,en;q=0.7' }
  'FR' = @{ timezone = 'Europe/Paris';       lang = 'fr-FR'; acceptLanguage = 'fr-FR,fr;q=0.9,en-US;q=0.8,en;q=0.7' }
  'NL' = @{ timezone = 'Europe/Amsterdam';   lang = 'nl-NL'; acceptLanguage = 'nl-NL,nl;q=0.9,en-US;q=0.8,en;q=0.7' }
  'AU' = @{ timezone = 'Australia/Sydney';   lang = 'en-AU'; acceptLanguage = 'en-AU,en;q=0.9' }
  'HK' = @{ timezone = 'Asia/Hong_Kong';     lang = 'zh-HK'; acceptLanguage = 'zh-HK,zh;q=0.9,en-US;q=0.8,en;q=0.7' }
  'TW' = @{ timezone = 'Asia/Taipei';        lang = 'zh-TW'; acceptLanguage = 'zh-TW,zh;q=0.9,en-US;q=0.8,en;q=0.7' }
  'IN' = @{ timezone = 'Asia/Kolkata';       lang = 'en-IN'; acceptLanguage = 'en-IN,en;q=0.9' }
  'BR' = @{ timezone = 'America/Sao_Paulo';  lang = 'pt-BR'; acceptLanguage = 'pt-BR,pt;q=0.9,en-US;q=0.8,en;q=0.7' }
  'ID' = @{ timezone = 'Asia/Jakarta';       lang = 'id-ID'; acceptLanguage = 'id-ID,id;q=0.9,en-US;q=0.8,en;q=0.7' }
  'MX' = @{ timezone = 'America/Mexico_City';lang = 'es-MX'; acceptLanguage = 'es-MX,es;q=0.9,en-US;q=0.8,en;q=0.7' }
  'ES' = @{ timezone = 'Europe/Madrid';      lang = 'es-ES'; acceptLanguage = 'es-ES,es;q=0.9,en-US;q=0.8,en;q=0.7' }
  'RU' = @{ timezone = 'Europe/Moscow';      lang = 'ru-RU'; acceptLanguage = 'ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7' }
  'AE' = @{ timezone = 'Asia/Dubai';         lang = 'en-AE'; acceptLanguage = 'en-AE,en;q=0.9' }
  'NZ' = @{ timezone = 'Pacific/Auckland';   lang = 'en-NZ'; acceptLanguage = 'en-NZ,en;q=0.9' }
}

function Assert-NotSymlink([string]$path) {
  if (-not $path) { return }
  if (Test-Path -LiteralPath $path) {
    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw "Refusing symlink or reparse point target at '$path'."
    }
  }
}

function Write-Utf8Atomic([string]$path, [string]$content) {
  Assert-NotSymlink $path
  $parent = Split-Path -Parent $path
  if ($parent) {
    Assert-NotSymlink $parent
    if (-not (Test-Path -LiteralPath $parent)) {
      New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
  }
  $tmp = "$path.tmp.$PID"
  Assert-NotSymlink $tmp
  Write-Utf8 $tmp $content
  Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Assert-ProfileDataIdentity([string]$userDataDir, [string]$instanceId) {
  Assert-NotSymlink $userDataDir
  if (-not (Test-Path -LiteralPath $userDataDir)) {
    New-Item -ItemType Directory -Path $userDataDir -Force | Out-Null
  }
  $identPath = Join-Path $userDataDir '.profile-identity.json'
  Assert-NotSymlink $identPath
  if (Test-Path -LiteralPath $identPath) {
    $existing = Get-Content -LiteralPath $identPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $existingId = if ($existing -and $existing.PSObject.Properties['instanceId']) { [string]$existing.instanceId } else { '' }
    if ($existingId -ne $instanceId) {
      throw "Profile identity mismatch in '$userDataDir': expected instanceId '$instanceId', found '$existingId'. Refusing to launch to prevent cross-account profile contamination."
    }
    return $existing
  }
  $payload = [ordered]@{
    contractVersion = 1
    instanceId      = $instanceId
    createdAt       = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  }
  Write-Utf8Atomic $identPath (($payload | ConvertTo-Json -Depth 4) + "`n")
  return $payload
}

function Ensure-ProfilePreferences([string]$userDataDir, [string]$lang) {
  Assert-NotSymlink $userDataDir
  if (-not (Test-Path -LiteralPath $userDataDir)) {
    New-Item -ItemType Directory -Path $userDataDir -Force | Out-Null
  }
  $devtoolsPort = Join-Path $userDataDir 'DevToolsActivePort'
  Assert-NotSymlink $devtoolsPort
  if (Test-Path -LiteralPath $devtoolsPort) {
    Remove-Item -LiteralPath $devtoolsPort -Force -ErrorAction SilentlyContinue
  }
  $defaultDir = Join-Path $userDataDir 'Default'
  Assert-NotSymlink $defaultDir
  if (-not (Test-Path -LiteralPath $defaultDir)) {
    New-Item -ItemType Directory -Path $defaultDir -Force | Out-Null
  }
  $prefsPath = Join-Path $defaultDir 'Preferences'
  Assert-NotSymlink $prefsPath

  $prefs = [pscustomobject]@{}
  if (Test-Path -LiteralPath $prefsPath) {
    try {
      $loaded = Get-Content -LiteralPath $prefsPath -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($loaded) { $prefs = $loaded }
    } catch {
      $prefs = [pscustomobject]@{}
    }
  }
  if (-not $prefs.PSObject.Properties['webrtc'] -or -not $prefs.webrtc) {
    Set-Prop $prefs 'webrtc' ([pscustomobject]@{})
  }
  Set-Prop $prefs.webrtc 'ip_handling_policy' 'disable_non_proxied_udp'
  Set-Prop $prefs.webrtc 'multiple_routes_enabled' $false
  Set-Prop $prefs.webrtc 'nonproxied_udp_enabled' $false

  if ($lang) {
    if (-not $prefs.PSObject.Properties['intl'] -or -not $prefs.intl) {
      Set-Prop $prefs 'intl' ([pscustomobject]@{})
    }
    Set-Prop $prefs.intl 'accept_languages' $lang
  }
  Write-Utf8Atomic $prefsPath (($prefs | ConvertTo-Json -Depth 10) + "`n")
  return $prefs
}

# ---------------------------------------------------------------- UDP leak guard
# 2026-11-03: Electron/Chromium 的 WebRTC 走裸 UDP，而 --proxy-server 只代理 TCP ——
# STUN 会从物理网卡直接打出去，真实公网 IP 随之暴露给对端（实测泄漏值与
# `curl --noproxy '*'` 得到的本机直连出口完全一致）。命令行层救不回来：
#   * `--force-webrtc-ip-handling-policy` 在 Chromium 156 里**不存在**，写了静默忽略；
#   * `--webrtc-ip-handling-policy` 的开关字符串在 Claude.exe 里根本搜不到（Electron 未编译进
#     该 switch），且即便主进程有，Electron 也不会把它下发给 renderer 的 WebRTC 实现；
#   * `webPreferences` 里的 webrtc.ip_handling_policy 同理，写进 Preferences 也不生效。
# 真正稳定生效的只有 Windows 防火墙按 exe 路径阻断出站 UDP：实测加上规则后
# STUN(3478/19302) 全部超时，撤掉规则立刻恢复泄漏。
# 放行 53/UDP 是刻意的：Chromium 的异步解析器会自己发 UDP DNS，整段封掉会把名字
# 解析一起掐死；而 WebRTC 泄露跟 53 无关。Windows 防火墙 Block 优先于 Allow，
# 所以只能在 Block 规则里用「排除 53」的方式表达，不能再加一条 Allow 兜。
function Get-UdpGuardRuleName([string]$instanceId) { "Claude Multi - block outbound UDP ($instanceId)" }

function Test-IsElevated {
  try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { return $false }
}

function Write-UdpGuardNote([string]$instanceId, [string]$message) {
  try {
    New-Item -ItemType Directory -Force $HomeRoot | Out-Null
    Add-Content -Path (Join-Path $HomeRoot 'launch-audit.log') -Encoding utf8 `
      -Value ("{0}  GUARD  {1}  {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $instanceId, $message)
  } catch { }
}

function Get-UdpGuardProgram([string]$instanceId) {
  # 返回规则当前绑定的 exe；无规则返回 $null，规则在但读不到程序路径返回 ''
  $rule = Get-NetFirewallRule -DisplayName (Get-UdpGuardRuleName $instanceId) -ErrorAction SilentlyContinue
  if (-not $rule) { return $null }
  $app = $rule | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue
  if (-not $app) { return '' }
  return [string]$app.Program
}

function Install-UdpLeakGuard([string]$instanceId, [string]$exePath) {
  if (-not (Test-IsElevated)) { throw 'administrator rights are required to change firewall rules' }
  $name = Get-UdpGuardRuleName $instanceId
  Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
  $common = @{
    DisplayName = $name; Direction = 'Outbound'; Program = $exePath; Protocol = 'UDP'
    Action = 'Block'; Profile = 'Any'; Enabled = 'True'
  }
  try {
    # 1-52 与 54-65535：等于「除 53 以外全部 UDP」
    New-NetFirewallRule @common -RemotePort @('1-52', '54-65535') -ErrorAction Stop | Out-Null
  } catch {
    # 某些旧版模块不接受端口段数组，退回整段阻断（极少数情况下会拖慢 DNS，但绝不漏）
    New-NetFirewallRule @common -ErrorAction Stop | Out-Null
  }
}

function Ensure-UdpLeakGuard([string]$instanceId, [string]$exePath) {
  # 幂等：已就位返回 present；缺失/路径过期则尝试安装；无提权时只记一条日志，绝不阻断启动。
  if (-not $exePath -or -not (Test-Path -LiteralPath $exePath)) { return 'skip' }
  $current = Get-UdpGuardProgram $instanceId
  if ($current -and ($current -ieq $exePath)) { return 'present' }
  if (-not (Test-IsElevated)) {
    $why = if ($current) { "stale program '$current' (want '$exePath')" } else { 'missing' }
    Write-UdpGuardNote $instanceId "UDP guard $why - run 'claude-multi.ps1 udp-guard' in an elevated shell to block WebRTC UDP"
    return 'needs-admin'
  }
  Install-UdpLeakGuard $instanceId $exePath
  Write-UdpGuardNote $instanceId "UDP guard installed for '$exePath' (all outbound UDP except 53 blocked)"
  return 'installed'
}

function Invoke-UdpGuard([string]$OnlyId) {
  # 手动入口：claude-multi.ps1 udp-guard [-Id <instance>]
  # 应用升级后 WindowsApps 路径会带新版本号，旧规则会失效 —— 升级完跑一次即可。
  $pkg = Get-ClaudePackage
  $pkgExe = Join-Path $pkg.InstallLocation 'app\Claude.exe'
  $targets = @((Read-Config).instances | Where-Object { $_.PSObject.Properties['proxy'] -and $_.proxy })
  if ($OnlyId) { $targets = @($targets | Where-Object id -eq $OnlyId) }
  if (-not $targets.Count) { 'no proxy-backed instance to guard'; return }
  $rows = foreach ($i in $targets) {
    $state = Ensure-UdpLeakGuard $i.id $pkgExe
    [pscustomobject]@{ Id = $i.id; Program = $pkgExe; State = $state }
  }
  $rows | Format-Table -AutoSize
}

function Invoke-ProxyGeoQuery([string]$url, [string]$proxyUrl) {
  $raw = $null
  if ($proxyUrl) {
    try { $raw = (& curl.exe -x $proxyUrl -s --max-time 6 $url 2>$null) -join "`n" } catch {}
  }
  if (-not $raw) {
    try {
      $irm = @{ Uri = $url; TimeoutSec = 6; ErrorAction = 'Stop' }
      if ($proxyUrl -and $proxyUrl -notmatch '^socks') { $irm['Proxy'] = $proxyUrl }
      return (Invoke-RestMethod @irm)
    } catch { return $null }
  }
  try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

function Test-ProxyGeoConsensus($i, [string]$userDataDir) {
  Assert-NotSymlink $userDataDir
  if (-not (Test-Path -LiteralPath $userDataDir)) {
    New-Item -ItemType Directory -Path $userDataDir -Force | Out-Null
  }
  $proxy = [string]$i.proxy
  $iid = [string]$i.id
  $policy = if ($i.PSObject.Properties['proxyExitPolicy'] -and $i.proxyExitPolicy) { ([string]$i.proxyExitPolicy).ToLower() } else { 'warn' }

  $s1 = $null; $s2 = $null
  $d1 = Invoke-ProxyGeoQuery 'https://ipwho.is/' $proxy
  if ($d1 -and ($d1.PSObject.Properties['success'] -eq $null -or $d1.success -ne $false)) {
    $ip1 = [string]$d1.ip
    $cc1 = ([string]($(if ($d1.PSObject.Properties['country_code'] -and $d1.country_code) { $d1.country_code } else { $d1.countryCode }))).Trim().ToUpper()
    $tz1 = if ($d1.timezone -and $d1.timezone.PSObject.Properties['id']) { [string]$d1.timezone.id } else { [string]$d1.timezone }
    if ($ip1 -and $cc1.Length -eq 2) {
      $s1 = @{ ip = $ip1; countryCode = $cc1; timezone = $tz1 }
    }
  }
  $d2 = Invoke-ProxyGeoQuery 'https://ipapi.co/json/' $proxy
  if ($d2 -and (-not $d2.error)) {
    $ip2 = [string]$d2.ip
    $cc2 = ([string]($(if ($d2.PSObject.Properties['country_code'] -and $d2.country_code) { $d2.country_code } else { $d2.country }))).Trim().ToUpper()
    $tz2 = [string]$d2.timezone
    if ($ip2 -and $cc2.Length -eq 2) {
      $s2 = @{ ip = $ip2; countryCode = $cc2; timezone = $tz2 }
    }
  }

  $geoConfidence = 'unreachable'
  $verifiedIp = $null
  $countryCode = $null
  $detectedTz = $null

  if ($s1 -and $s2) {
    if ($s1.countryCode -ne $s2.countryCode -or $s1.ip -ne $s2.ip) {
      $geoConfidence = 'conflict'
    } else {
      $geoConfidence = 'high'
    }
    $verifiedIp = $s1.ip
    $countryCode = $s1.countryCode
    $detectedTz = if ($s1.timezone) { $s1.timezone } else { $s2.timezone }
  } elseif ($s1 -or $s2) {
    $chosen = if ($s1) { $s1 } else { $s2 }
    $geoConfidence = 'single'
    $verifiedIp = $chosen.ip
    $countryCode = $chosen.countryCode
    $detectedTz = $chosen.timezone
  }

  $netDefaults = if ($countryCode -and $script:CountryNetworkMap.ContainsKey($countryCode)) { $script:CountryNetworkMap[$countryCode] } else { @{} }
  $explicitTz = if ($i.PSObject.Properties['timezone'] -and $i.timezone) { [string]$i.timezone } else { '' }
  $resolvedTz = if ($explicitTz -and $explicitTz -ne 'auto') { $explicitTz } elseif ($detectedTz) { $detectedTz } elseif ($netDefaults.timezone) { $netDefaults.timezone } else { 'UTC' }

  $explicitLang = if ($i.PSObject.Properties['lang'] -and $i.lang) { [string]$i.lang } else { '' }
  $resolvedLang = if ($explicitLang -and $explicitLang -ne 'auto') { $explicitLang } elseif ($netDefaults.lang) { $netDefaults.lang } else { 'en-US' }
  $acceptLang = if ($netDefaults.acceptLanguage) { $netDefaults.acceptLanguage } else { "$resolvedLang,en;q=0.9" }

  $identPath = Join-Path $userDataDir '.proxy-identity.json'
  Assert-NotSymlink $identPath
  $proxyShown = $proxy -replace '(://)[^/\s]*@', '$1***@'
  $prevIp = $null
  if (Test-Path -LiteralPath $identPath) {
    try {
      $prev = Get-Content -LiteralPath $identPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $sameInst = (-not $prev.PSObject.Properties['instanceId']) -or ($prev.instanceId -eq $iid)
      $sameScope = (-not $prev.PSObject.Properties['proxyScope']) -or (-not $prev.proxyScope) -or ($prev.proxyScope -eq $proxyShown)
      if ($prev -and $sameInst -and $sameScope) {
        $prevIp = [string]$prev.verifiedIp
      }
    } catch {}
  }

  $ipDrifted = [bool]($prevIp -and $verifiedIp -and ($prevIp -ne $verifiedIp))

  if ($policy -eq 'block') {
    if ($geoConfidence -eq 'unreachable') {
      throw "Proxy exit verification failed for '$iid': both GeoIP sources unreachable under strict block policy."
    }
    if ($geoConfidence -eq 'conflict') {
      throw "Proxy GeoIP consensus conflict for '$iid': $($s1.ip)/$($s1.countryCode) vs $($s2.ip)/$($s2.countryCode) (proxyExitPolicy=block)."
    }
    if ($ipDrifted) {
      throw "Proxy exit IP drift detected for '$iid': previous verifiedIp '$prevIp' != current '$verifiedIp' (proxyExitPolicy=block)."
    }
    # 2026-11-02: 时区与出口地理不一致 = 自相矛盾的 locale 信号（IP 在 A 地、系统时区在 B 地），
    # 这是风控最容易抓的特征组合。strict 下宁可不起，也不带着矛盾指纹跑。
    if ($explicitTz -and $explicitTz -ne 'auto' -and $detectedTz -and ($explicitTz -ne $detectedTz)) {
      $geoStrict = if ($i.PSObject.Properties['geoStrict']) { [bool]$i.geoStrict } else { $true }
      if ($geoStrict) {
        throw "Proxy exit geography mismatch for '$iid': configured timezone '$explicitTz' but exit '$verifiedIp' ($countryCode) resolves to '$detectedTz'. Fix instances.json timezone, or set `"geoStrict`": false to downgrade this check."
      }
    }
  }

  $record = [ordered]@{
    contractVersion    = 1
    instanceId         = $iid
    proxyScope         = $proxyShown
    verifiedIp         = $verifiedIp
    previousVerifiedIp = $prevIp
    ipDrifted          = $ipDrifted
    countryCode        = $countryCode
    timezone           = $resolvedTz
    lang               = $resolvedLang
    acceptLanguage     = $acceptLang
    geoConfidence      = $geoConfidence
    verifiedAt         = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  }

  if ($verifiedIp) {
    Write-Utf8Atomic $identPath (($record | ConvertTo-Json -Depth 4) + "`n")
  }
  return [pscustomobject]$record
}

function Write-ShieldScript([string]$userDataDir) {
  Assert-NotSymlink $userDataDir
  if (-not (Test-Path -LiteralPath $userDataDir)) {
    New-Item -ItemType Directory -Path $userDataDir -Force | Out-Null
  }
  $shieldPath = Join-Path $userDataDir 'shield.cjs'
  $shieldCode = @'
'use strict';
const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');

const PROXY_URL = process.env.CLAUDE_MULTI_PROXY_URL || '';
const STARTUP_IP = (process.env.CLAUDE_MULTI_STARTUP_IP || '').trim();
const EXIT_POLICY = (process.env.CLAUDE_MULTI_EXIT_POLICY || (STARTUP_IP ? 'block' : 'warn')).toLowerCase();
const MONITOR_INTERVAL_MS = Math.max(5000, parseInt(process.env.CLAUDE_MULTI_MONITOR_INTERVAL_MS || '300000', 10) || 300000);
const USER_DATA_DIR = process.env.CLAUDE_MULTI_USER_DATA_DIR || '';

let _networkQuarantined = false;
let _quarantineReason = '';
let _consecutiveFailures = 0;

function isLocalHost(host) {
  if (!host) return false;
  const h = String(host).toLowerCase().replace(/^\[|\]$/g, '').split(':')[0];
  return h === 'localhost' || h === '127.0.0.1' || h === '::1';
}

function extractTargetHost(input, options) {
  try {
    if (typeof input === 'string' || input instanceof URL) {
      const u = new URL(String(input));
      return u.hostname;
    }
    if (input && typeof input === 'object') {
      return input.hostname || input.host || (options && (options.hostname || options.host)) || '';
    }
  } catch (_) {}
  if (options && typeof options === 'object') {
    return options.hostname || options.host || '';
  }
  return '';
}

function writeQuarantineLog(reason) {
  if (!USER_DATA_DIR) return;
  try {
    if (!fs.existsSync(USER_DATA_DIR) || fs.lstatSync(USER_DATA_DIR).isSymbolicLink()) return;
    const logPath = path.join(USER_DATA_DIR, '.proxy-quarantine.log');
    if (fs.existsSync(logPath) && fs.lstatSync(logPath).isSymbolicLink()) return;
    const line = `${new Date().toISOString()} [QUARANTINE] policy=${EXIT_POLICY} startupIp=${STARTUP_IP} reason=${reason}\n`;
    fs.appendFileSync(logPath, line, { encoding: 'utf8', mode: 0o600 });
  } catch (_) {}
}

function tripQuarantine(reason) {
  _quarantineReason = String(reason || 'proxy exit drift detected');
  writeQuarantineLog(_quarantineReason);
  if (EXIT_POLICY === 'block') {
    _networkQuarantined = true;
  }
}

function assertNotQuarantined(host) {
  if (_networkQuarantined && !isLocalHost(host)) {
    throw new Error(`[Claude-Multi Shield] Network quarantined due to proxy exit drift: ${_quarantineReason}`);
  }
}

const origHttpRequest = http.request;
http.request = function(input, options, cb) {
  assertNotQuarantined(extractTargetHost(input, options));
  return origHttpRequest.apply(this, arguments);
};

const origHttpGet = http.get;
http.get = function(input, options, cb) {
  assertNotQuarantined(extractTargetHost(input, options));
  return origHttpGet.apply(this, arguments);
};

const origHttpsRequest = https.request;
https.request = function(input, options, cb) {
  assertNotQuarantined(extractTargetHost(input, options));
  return origHttpsRequest.apply(this, arguments);
};

const origHttpsGet = https.get;
https.get = function(input, options, cb) {
  assertNotQuarantined(extractTargetHost(input, options));
  return origHttpsGet.apply(this, arguments);
};

if (typeof globalThis.fetch === 'function') {
  const origFetch = globalThis.fetch;
  globalThis.fetch = function(input, init) {
    try {
      const urlStr = (typeof input === 'string' || input instanceof URL) ? String(input) : (input && input.url ? input.url : '');
      assertNotQuarantined(extractTargetHost(urlStr, init));
    } catch (err) {
      return Promise.reject(err);
    }
    return origFetch.apply(this, arguments);
  };
}

function probeExitIpOnce(url, cb) {
  const curlBin = process.platform === 'win32' ? 'curl.exe' : 'curl';
  execFile(curlBin, ['-x', PROXY_URL, '-s', '--max-time', '6', url], { timeout: 7000, maxBuffer: 65536 }, (err, stdout) => {
    if (err || !stdout) return cb(null);
    try {
      const data = JSON.parse(stdout);
      const ip = String(data.ip || '').trim();
      return cb(ip || null);
    } catch (_) {
      return cb(null);
    }
  });
}

function verifyRuntimeExitIp() {
  probeExitIpOnce('https://ipwho.is/', (ip1) => {
    if (ip1) {
      _consecutiveFailures = 0;
      if (ip1 !== STARTUP_IP) {
        tripQuarantine(`exit IP drifted from ${STARTUP_IP} to ${ip1}`);
      }
      return;
    }
    probeExitIpOnce('https://api.ipify.org?format=json', (ip2) => {
      if (ip2) {
        _consecutiveFailures = 0;
        if (ip2 !== STARTUP_IP) {
          tripQuarantine(`exit IP drifted from ${STARTUP_IP} to ${ip2}`);
        }
        return;
      }
      _consecutiveFailures += 1;
      if (_consecutiveFailures >= 2) {
        tripQuarantine(`proxy unreachable for ${_consecutiveFailures} consecutive checks`);
      }
    });
  });
}

if (PROXY_URL && STARTUP_IP) {
  const timer = setInterval(verifyRuntimeExitIp, MONITOR_INTERVAL_MS);
  if (timer && typeof timer.unref === 'function') {
    timer.unref();
  }
}

module.exports = {
  isQuarantined: () => _networkQuarantined,
  getQuarantineReason: () => _quarantineReason,
  tripQuarantine,
};
'@
  Write-Utf8Atomic $shieldPath ($shieldCode.Replace("`r`n", "`n") + "`n")
  return $shieldPath
}
function Read-Config {
  $c = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if (-not $c.PSObject.Properties['settings']) { $c | Add-Member settings ([pscustomobject]@{}) }
  if (-not $c.settings.PSObject.Properties['syncSessions']) { $c.settings | Add-Member syncSessions $true }
  if (-not $c.settings.PSObject.Properties['protocol'])     { $c.settings | Add-Member protocol 'last' }
  if (-not $c.settings.PSObject.Properties['language'])        { $c.settings | Add-Member language 'en' }
  if (-not $c.settings.PSObject.Properties['syncSettings'])    { $c.settings | Add-Member syncSettings $true }
  if (-not $c.settings.PSObject.Properties['notifyReload'])    { $c.settings | Add-Member notifyReload $false }
  if (-not $c.settings.PSObject.Properties['liveRefresh'])    { $c.settings | Add-Member liveRefresh $false }
  if (-not $c.settings.PSObject.Properties['refreshOfficial']) { $c.settings | Add-Member refreshOfficial $false }
  $c
}
function Save-Config($cfg) { Write-Utf8 $ConfigPath ($cfg | ConvertTo-Json -Depth 8) }
function Set-Prop($obj, $name, $value) {
  if ($obj.PSObject.Properties[$name]) { $obj.$name = $value } else { $obj | Add-Member $name $value }
}
function Get-Palettes { Get-Content (Join-Path $Root 'palettes.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
function Get-Instance($id) {
  $i = (Read-Config).instances | Where-Object id -eq $id
  if (-not $i) { throw "No instance '$id' in instances.json" }
  $i
}
function Read-State { try { Get-Content $StatePath -Raw | ConvertFrom-Json } catch { [pscustomobject]@{ lastActive = '' } } }
function Save-State($s) { New-Item -ItemType Directory -Force $StateDir | Out-Null; Write-Utf8 $StatePath ($s | ConvertTo-Json) }

# ---------------------------------------------------------------- instance paths
function Get-DataDir($i) {          # the Claude userData directory of an instance
  if ($i.kind -eq 'official') {
    if ($i.id -eq 'official') { return $OfficialDir }
    return (Join-Path $HomeRoot "$($i.id)\Data")
  }
  if ($i.id -eq '3p') { return $SourceDir }                      # the primary 3P instance keeps the stock location
  Join-Path $HomeRoot "$($i.id)\Local\Claude-3p"
}
function Get-FakeLocal($i) { Join-Path $HomeRoot "$($i.id)\Local" }
function Get-Aumid($i) { if ($i.kind -eq 'official' -and $i.id -eq 'official') { $OfficialAumid } else { "ClaudeMulti.$($i.id)" } }
function Get-IconPath($i) { Join-Path $IconDir "$($i.id).ico" }
function Get-DesktopLink($i) { Join-Path ([Environment]::GetFolderPath('Desktop')) ($i.name + '.lnk') }
function Get-Shim($i) { "`"$Wscript`" //B //Nologo `"$Root\run.vbs`" $($i.id)" }

# ---------------------------------------------------------------- processes
function Get-ClaudeMains {          # every Claude Desktop main process (not helpers, not the Claude Code CLI)
  Get-CimInstance Win32_Process -Filter "Name='Claude.exe'" | Where-Object {
    $_.ExecutablePath -and $_.ExecutablePath -like '*\AnthropicPBC.Claude_*' -and $_.CommandLine -and $_.CommandLine -notmatch '--type='
  }
}
function Find-InstanceOf($proc, $instances) {
  foreach ($i in $instances) {
    if ($i.kind -eq 'official' -and $i.id -eq 'official') { continue }
    $dd = Get-DataDir $i
    if ($proc.CommandLine -match [regex]::Escape('--user-data-dir') -and $proc.CommandLine -match [regex]::Escape($dd)) { return $i }
  }
  if ($proc.CommandLine -notmatch '--user-data-dir') { return ($instances | Where-Object { $_.kind -eq 'official' -and $_.id -eq 'official' } | Select-Object -First 1) }
}
function Get-Roots($i) {
  $all = @((Read-Config).instances)
  Get-ClaudeMains | Where-Object { $x = Find-InstanceOf $_ $all; $x -and $x.id -eq $i.id }
}

# ---------------------------------------------------------------- profiles (what makes an instance 3P)
function Get-NewestWrite($dir) {
  if (-not (Test-Path $dir)) { return [datetime]::MinValue }
  $f = Get-ChildItem $dir -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($f) { $f.LastWriteTime } else { [datetime]::MinValue }
}
function Write-Profile($dst, $id, $name, $profileObj) {
  New-Item -ItemType Directory -Force $dst | Out-Null
  Get-ChildItem $dst -File | Remove-Item -Force
  Write-Utf8 (Join-Path $dst "$id.json") ($profileObj | ConvertTo-Json -Depth 8)
  Write-Utf8 (Join-Path $dst '_meta.json') (@{ entries = @(@{ id = $id; name = $name }); appliedId = $id } | ConvertTo-Json -Depth 4)
}
function Sync-Profile($i, $data) {   # give a non-primary instance its own copy of its profile; returns the profile's timestamp
  $dst = Join-Path $data 'configLibrary'
  $uid = '00000000-0000-4000-8000-0000000000' + ('{0:D2}' -f ([Math]::Abs($i.id.GetHashCode()) % 100))
  if ($i.profile) {                  # hand-written profile JSON
    $src = [Environment]::ExpandEnvironmentVariables($i.profile)
    Write-Profile $dst $uid $i.name (Get-Content $src -Raw | ConvertFrom-Json)
    return (Get-Item $src).LastWriteTime
  }
  if ($i.provider) {                 # direct profile built from one cc-switch provider (own upstream, no shared gateway)
    $json = (New-DirectProfile $i.provider) | ConvertTo-Json -Depth 8
    $file = Join-Path $dst "$uid.json"
    if ((Test-Path $file) -and ((Get-Content $file -Raw) -eq $json)) { return (Get-Item $file).LastWriteTime }
    Write-Profile $dst $uid $i.name ($json | ConvertFrom-Json)
    return (Get-Date)
  }
  $src = Join-Path $SourceDir 'configLibrary'      # follow cc-switch's current selection
  if (-not (Test-Path $src)) { return [datetime]::MinValue }
  Get-ChildItem $dst -File -ErrorAction SilentlyContinue | Remove-Item -Force
  New-Item -ItemType Directory -Force $dst | Out-Null
  Copy-Item "$src\*" $dst -Force
  Get-NewestWrite $src
}

# the official app must never read a cc-switch profile: give it a private LOCALAPPDATA whose Claude-3p is empty
function Initialize-OfficialHome([string]$id = 'official') {
  $h = Join-Path $HomeRoot "$id\Local"
  New-Item -ItemType Directory -Force (Join-Path $h 'Claude-3p') | Out-Null
  foreach ($n in 'Claude', 'Packages') {
    $real = Join-Path $RealLocal $n; $link = Join-Path $h $n
    if ((Test-Path $real) -and -not (Test-Path $link)) { & cmd.exe /c mklink /J "`"$link`"" "`"$real`"" | Out-Null }
  }
  $h
}

# ---------------------------------------------------------------- launching
function Test-AgentRunning { $m = $null; if ([Threading.Mutex]::TryOpenExisting('Local\ClaudeMultiAgent', [ref]$m)) { $m.Dispose(); $true } else { $false } }
function Start-Agent {
  if (Test-AgentRunning) { return }
  Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$Root\claude-multi.ps1`"", 'agent'
}

function Initialize-InstanceEnv($i) {
  $data = Get-DataDir $i
  if (-not (Test-Path $data)) { New-Item -ItemType Directory -Force $data | Out-Null }
  if ($i.kind -eq 'official') {
    if ($i.id -ne 'official') {
      Initialize-OfficialHome $i.id | Out-Null
      $cfgLib = Join-Path $data 'configLibrary'
      if (Test-Path $cfgLib) { Remove-Item -Path $cfgLib -Recurse -Force }
    }
  } else {
    $fake = Get-FakeLocal $i
    if (-not (Test-Path $fake)) { New-Item -ItemType Directory -Force (Join-Path $fake 'Claude-3p') | Out-Null }
    if ($data -ne $SourceDir) { Sync-Profile $i $data | Out-Null }
  }

  # Link/sync claude_desktop_config.json (MCP tools, Nowledge Mem)
  $canonicalCfg = Join-Path $OfficialDir 'claude_desktop_config.json'
  $instCfg = Join-Path $data 'claude_desktop_config.json'
  if ((Test-Path $canonicalCfg) -and -not (Test-Path $instCfg)) {
    try { & cmd.exe /c mklink /H "`"$instCfg`"" "`"$canonicalCfg`"" | Out-Null }
    catch { Copy-Item -Path $canonicalCfg -Destination $instCfg -Force }
  }

  # Link sessions & agent storage if enabled
  if ((Read-Config).settings.syncSessions -ne $false) {
    foreach ($sessDir in 'claude-code-sessions', 'local-agent-mode-sessions') {
      $realSess = Join-Path $OfficialDir $sessDir
      $linkSess = Join-Path $data $sessDir
      if ((Test-Path $realSess) -and -not (Test-Path $linkSess)) {
        & cmd.exe /c mklink /J "`"$linkSess`"" "`"$realSess`"" | Out-Null
      }
    }
  }

  # Generate colored icon and create/wire shortcuts
  if (-not ($i.kind -eq 'official' -and $i.id -eq 'official')) {
    Assert-ProfileDataIdentity $data $i.id | Out-Null
  }
  $initLang = if ($i.PSObject.Properties['lang'] -and $i.lang -and $i.lang -ne 'auto') { [string]$i.lang } else { '' }
  Ensure-ProfilePreferences $data $initLang | Out-Null
  Write-ShieldScript $data | Out-Null
  Update-Icons @($i) -Force
  if ($i.kind -eq 'official' -and $i.id -eq 'official') {
    foreach ($l in @(Get-OfficialLinks | Where-Object { Test-Path $_ })) { Set-Link $l $i }
  } else {
    Set-Link (Get-DesktopLink $i) $i
    Update-PinnedLinks $i
  }

  [pscustomobject]@{
    Id              = $i.id
    Name            = $i.name
    Kind            = $i.kind
    DataDir         = $data
    DataDirExists   = (Test-Path $data)
    MCPConfigExists = (Test-Path $instCfg)
    SessionsLinked  = (Test-Path (Join-Path $data 'claude-code-sessions'))
    IconFile        = (Get-IconPath $i)
    DesktopShortcut = (Get-DesktopLink $i)
  }
}

function Test-InstancePurity($i) {
  $proxy = if ($i.proxy) { $i.proxy } else { "http://127.0.0.1:7890" }
  $proxyShown = $proxy -replace '(://)[^/\s]*@', '$1***@'       # report only the masked form (output may be truncated/logged)
  $tzExpected = $i.timezone

  $hasAuth = if ($i.proxy -and ($i.proxy -match '://[^/@\s]+@' -or $i.proxy -match '^[^/@\s]+@')) { $true } else { $false }
  $authWarning = if ($hasAuth) { "Chromium --proxy-server does not accept embedded credentials. For authenticated upstream proxies, route through a local unauthenticated gateway (e.g. 127.0.0.1:port) like cc-switch, Clash, or v2ray." } else { $null }
  if ($authWarning) { Write-Warning $authWarning }

  $rawIp = $null
  try {
    $rawIp = curl.exe -x $proxy -s "https://api.ipify.org" --connect-timeout 8
    if (-not $rawIp -or $rawIp -notmatch '^\d+\.\d+\.\d+\.\d+$') {
      $rawIp = (Invoke-RestMethod -Uri "https://api.ipify.org" -Proxy $proxy -TimeoutSec 8)
    }
  } catch {
    $rawIp = $null
  }

  if (-not $rawIp) {
    return [pscustomobject]@{
      Id            = $i.id
      Name          = $i.name
      Proxy         = $proxyShown
      ExitIP        = 'Connection Failed'
      Location      = 'Unknown'
      IPType        = 'Unknown'
      RiskScore     = 'N/A'
      ClaudeStatus  = 'Unreachable'
      TimezoneMatch = 'N/A'
      Warning       = $authWarning
    }
  }

  $riskInfo = try { Invoke-RestMethod -Uri "https://api.ipquery.io/$rawIp" -TimeoutSec 8 } catch { $null }
  $geoInfo  = try { Invoke-RestMethod -Uri "http://ip-api.com/json/$rawIp" -TimeoutSec 8 } catch { $null }

  $city = if ($geoInfo) { "$($geoInfo.city), $($geoInfo.countryCode)" } else { "Unknown" }
  $isRes = if ($riskInfo) { if ($riskInfo.risk.is_datacenter) { 'Datacenter' } else { 'Residential' } } else { 'Unknown' }
  $riskScore = if ($riskInfo) { "$($riskInfo.risk.risk_score)/100" } else { 'Unknown' }
  $ipTz = if ($geoInfo) { $geoInfo.timezone } else { 'Unknown' }

  $supportedCc = @('US', 'CA', 'GB', 'ID', 'JP', 'SG', 'DE', 'FR', 'AU')
  $isSupported = if ($geoInfo) { if ($geoInfo.countryCode -in $supportedCc) { 'Supported' } else { 'Restricted' } } else { 'Unknown' }

  $tzMatched = if ($tzExpected) {
    if ($ipTz -eq $tzExpected) { 'Matched (100%)' } else { "Mismatch ($ipTz)" }
  } else {
    "Not Set ($ipTz)"
  }

  [pscustomobject]@{
    Id            = $i.id
    Name          = $i.name
    Proxy         = $proxyShown
    ExitIP        = $rawIp
    Location      = $city
    IPType        = $isRes
    RiskScore     = $riskScore
    ClaudeStatus  = $isSupported
    TimezoneMatch = $tzMatched
    Warning       = $authWarning
  }
}

# ---------------------------------------------------------------- chat font (.asar index.html patch & cached runtime)
function Get-ChatFontInjectionMarkup([string]$ChatFont) {
  if ([string]::IsNullOrWhiteSpace($ChatFont)) { return '' }
  $slug = ($ChatFont.Trim().ToLowerInvariant() -replace '[^a-z0-9_-]', '')
  if ($slug -notin @('anthropic-serif', 'serif')) { return '' }
  $snippet = @'
<style id="claude-multi-chat-font">
:root, html, body, .cds-root, [data-theme], [data-font], [class*="--font-claude-response"] {
  --font-cjk-serif-lead-sc: "Noto Serif SC", "Source Han Serif SC", "Noto Serif CJK SC", "Songti SC", "STSong" !important;
  --font-claude-response: var(--font-anthropic-serif, "anthropic-serif", "Anthropic Serif", Georgia, "Times New Roman", serif) !important;
  --font-user-message: var(--font-anthropic-serif, "anthropic-serif", "Anthropic Serif", Georgia, "Times New Roman", serif) !important;
  --cds-font-voice: var(--font-anthropic-serif, "anthropic-serif", "Anthropic Serif", Georgia, serif) !important;
}
.prose, .prose[data-prose-font], .prose[data-prose-font="sans"] {
  --_prose-font-body: var(--_prose-face-serif, var(--font-anthropic-serif)) !important;
  --_prose-font-heading: var(--_prose-face-serif, var(--font-anthropic-serif)) !important;
  --_prose-font-heading-display: var(--_prose-face-serif, var(--font-anthropic-serif)) !important;
  --_prose-heading-weight: var(--cds-prose-weight-heading-serif, 520) !important;
}
.font-claude-response, .font-claude-response-body, .font-user-message, [data-testid="user-message"] {
  font-family: var(--font-anthropic-serif, "anthropic-serif", "Anthropic Serif", Georgia, "Noto Serif SC", serif) !important;
}
.prose pre, .prose code, .font-claude-response pre, .font-claude-response code, .font-user-message pre, .font-user-message code {
  font-family: var(--_prose-face-mono, var(--font-mono, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace)) !important;
}
</style><script id="claude-multi-chat-font-sync">try{localStorage.setItem("LSS-customStyles:chatFont",JSON.stringify({value:"serif"}));localStorage.setItem("LSS-customStyles:chatFontSynced",JSON.stringify({value:true}));}catch(_){}</script>
'@
  return ($snippet -replace "`r`n", "`n")
}

function Test-IsReparsePoint([string]$LiteralPath) {
  if ([string]::IsNullOrWhiteSpace($LiteralPath)) { return $false }
  $attr = [System.IO.File]::GetAttributes($LiteralPath)
  if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Refusing to operate on symlink or reparse point: $LiteralPath"
  }
  return $false
}

function Remove-HtmlElementByOpenTag([string]$Html, [string]$OpenTag, [string]$CloseTag) {
  if ([string]::IsNullOrEmpty($Html)) { return $Html }
  $sb = New-Object System.Text.StringBuilder($Html.Length)
  $pos = 0
  while ($true) {
    $start = $Html.IndexOf($OpenTag, $pos, [System.StringComparison]::OrdinalIgnoreCase)
    if ($start -lt 0) {
      [void]$sb.Append($Html, $pos, $Html.Length - $pos)
      break
    }
    $end = $Html.IndexOf($CloseTag, $start + $OpenTag.Length, [System.StringComparison]::OrdinalIgnoreCase)
    if ($end -lt 0) {
      [void]$sb.Append($Html, $pos, $Html.Length - $pos)
      break
    }
    [void]$sb.Append($Html, $pos, $start - $pos)
    $pos = $end + $CloseTag.Length
  }
  return $sb.ToString()
}

function Read-ExactBytes([System.IO.Stream]$Stream, [int]$Count) {
  $buf = New-Object byte[] $Count
  $offset = 0
  while ($offset -lt $Count) {
    $n = $Stream.Read($buf, $offset, $Count - $offset)
    if ($n -le 0) { throw "Unexpected EOF while reading $Count bytes from ASAR archive." }
    $offset += $n
  }
  return $buf
}

function Move-FileAtomically([string]$TempPath, [string]$DestPath) {
  $destExists = $false
  try {
    [void][System.IO.File]::GetAttributes($DestPath)
    $destExists = $true
  } catch [System.IO.FileNotFoundException], [System.IO.DirectoryNotFoundException] {
    $destExists = $false
  }
  if ($destExists) {
    [void](Test-IsReparsePoint $DestPath)
    $attr = [System.IO.File]::GetAttributes($DestPath)
    if (($attr -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
      [System.IO.File]::SetAttributes($DestPath, ($attr -band (-bnot [System.IO.FileAttributes]::ReadOnly)))
    }
    [System.IO.File]::Replace($TempPath, $DestPath, $null, $true)
  } else {
    [System.IO.File]::Move($TempPath, $DestPath)
  }
}

function Update-AsarIndexHtmlFontPatch([string]$SourceAsar, [string]$DestAsar, [string]$ChatFont) {
  $markup = Get-ChatFontInjectionMarkup $ChatFont
  if ([string]::IsNullOrWhiteSpace($markup)) {
    throw "Unsupported chatFont value: '$ChatFont'"
  }
  [void](Test-IsReparsePoint $SourceAsar)
  $srcParent = Split-Path -Parent $SourceAsar
  if ($srcParent -and (Test-Path -LiteralPath $srcParent)) { [void](Test-IsReparsePoint $srcParent) }
  if (-not [System.IO.File]::Exists($SourceAsar)) {
    throw "Source ASAR archive not found: $SourceAsar"
  }

  $destParent = Split-Path -Parent $DestAsar
  if ($destParent) {
    if (Test-Path -LiteralPath $destParent) {
      [void](Test-IsReparsePoint $destParent)
    } else {
      New-Item -ItemType Directory -Force -Path $destParent | Out-Null
      [void](Test-IsReparsePoint $destParent)
    }
  }
  try {
    [void](Test-IsReparsePoint $DestAsar)
  } catch [System.IO.FileNotFoundException], [System.IO.DirectoryNotFoundException] {
  }

  if (-not ('System.Web.Script.Serialization.JavaScriptSerializer' -as [type])) {
    Add-Type -AssemblyName System.Web.Extensions
  }
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  $tmpPath = "$DestAsar.tmp.$PID"
  try {
    [void](Test-IsReparsePoint $tmpPath)
    if ([System.IO.File]::Exists($tmpPath)) { [System.IO.File]::Delete($tmpPath) }
  } catch [System.IO.FileNotFoundException], [System.IO.DirectoryNotFoundException] {
  }

  $inStream = $null
  $outStream = $null
  $sha = $null
  try {
    $inStream = New-Object System.IO.FileStream($SourceAsar, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    if ($inStream.Length -lt 16) {
      throw "Invalid ASAR archive (too small: $($inStream.Length) bytes): $SourceAsar"
    }
    $hdr = Read-ExactBytes $inStream 16
    $u0 = [BitConverter]::ToUInt32($hdr, 0)
    $u1 = [BitConverter]::ToUInt32($hdr, 4)
    $u2 = [BitConverter]::ToUInt32($hdr, 8)
    $jlen = [BitConverter]::ToUInt32($hdr, 12)
    if ($u0 -ne 4 -or $jlen -le 0 -or $jlen -gt 67108864) {
      throw "Invalid ASAR pickle header (u0=$u0, jlen=$jlen)"
    }
    $dataStart = [int64]8 + [int64]$u1
    if ($dataStart -lt ([int64]16 + [int64]$jlen) -or $dataStart -gt $inStream.Length) {
      throw "Invalid ASAR data boundary (dataStart=$dataStart, fileLen=$($inStream.Length))"
    }
    $origPayloadLen = $inStream.Length - $dataStart

    $jsonBytes = Read-ExactBytes $inStream ([int]$jlen)
    $jsonText = [System.Text.Encoding]::UTF8.GetString($jsonBytes)
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = [int]::MaxValue
    $ser.RecursionLimit = 256
    $root = $ser.DeserializeObject($jsonText)
    if ($null -eq $root -or -not $root.ContainsKey('files')) {
      throw "Invalid ASAR JSON header: missing root 'files' dictionary"
    }
    $filesMap = $root['files']
    if ($null -eq $filesMap -or -not $filesMap.ContainsKey('index.html')) {
      throw "ASAR archive does not contain a root 'index.html' file entry"
    }
    $idxEntry = $filesMap['index.html']
    if ($null -eq $idxEntry -or -not $idxEntry.ContainsKey('offset') -or -not $idxEntry.ContainsKey('size')) {
      throw "ASAR 'index.html' entry is unpacked or missing offset/size"
    }

    $origOffset = [int64]::Parse([string]$idxEntry['offset'], [System.Globalization.CultureInfo]::InvariantCulture)
    $origSizeLong = [int64]::Parse([string]$idxEntry['size'], [System.Globalization.CultureInfo]::InvariantCulture)
    if ($origOffset -lt 0 -or $origSizeLong -lt 0 -or $origSizeLong -gt 16777216 -or ($origOffset + $origSizeLong) -gt $origPayloadLen) {
      throw "Invalid ASAR 'index.html' bounds (offset=$origOffset, size=$origSizeLong)"
    }
    $origSize = [int]$origSizeLong

    $inStream.Position = $dataStart + $origOffset
    $origHtmlBytes = Read-ExactBytes $inStream $origSize
    $origHtml = [System.Text.Encoding]::UTF8.GetString($origHtmlBytes)

    $cleanHtml = Remove-HtmlElementByOpenTag $origHtml '<style id="claude-multi-chat-font">' '</style>'
    $cleanHtml = Remove-HtmlElementByOpenTag $cleanHtml '<script id="claude-multi-chat-font-sync">' '</script>'
    $headIdx = $cleanHtml.IndexOf('</head>', [System.StringComparison]::OrdinalIgnoreCase)
    if ($headIdx -ge 0) {
      $newHtml = $cleanHtml.Substring(0, $headIdx) + $markup + $cleanHtml.Substring($headIdx)
    } else {
      $newHtml = $cleanHtml + $markup
    }
    $newHtmlBytes = $utf8NoBom.GetBytes($newHtml)

    $blockSize = 4194304
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fullHash = ([BitConverter]::ToString($sha.ComputeHash($newHtmlBytes)) -replace '-', '').ToLowerInvariant()
    $blockList = New-Object System.Collections.Generic.List[string]
    for ($pos = 0; $pos -lt $newHtmlBytes.Length; $pos += $blockSize) {
      $chunkLen = [Math]::Min($blockSize, $newHtmlBytes.Length - $pos)
      $bHash = ([BitConverter]::ToString($sha.ComputeHash($newHtmlBytes, $pos, $chunkLen)) -replace '-', '').ToLowerInvariant()
      $blockList.Add($bHash)
    }

    $basePayloadLen = if (($origOffset + $origSizeLong) -eq $origPayloadLen) { $origOffset } else { $origPayloadLen }
    $idxEntry['size'] = [int]$newHtmlBytes.Length
    $idxEntry['offset'] = $basePayloadLen.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    $idxEntry['integrity'] = @{
      algorithm = 'SHA256'
      hash      = $fullHash
      blockSize = $blockSize
      blocks    = $blockList.ToArray()
    }

    $newJsonBytes = $utf8NoBom.GetBytes($ser.Serialize($root))
    $newJlen = [uint32]$newJsonBytes.Length
    $alignedJlen = [uint32](($newJsonBytes.Length + 3) -band (-bnot 3))
    $padLen = [int]($alignedJlen - $newJlen)
    $newU1 = [uint32]($alignedJlen + 8)
    $newU2 = [uint32]($alignedJlen + 4)

    $newHdr = New-Object byte[] 16
    [Array]::Copy([BitConverter]::GetBytes([uint32]4), 0, $newHdr, 0, 4)
    [Array]::Copy([BitConverter]::GetBytes($newU1), 0, $newHdr, 4, 4)
    [Array]::Copy([BitConverter]::GetBytes($newU2), 0, $newHdr, 8, 4)
    [Array]::Copy([BitConverter]::GetBytes($newJlen), 0, $newHdr, 12, 4)

    $outStream = New-Object System.IO.FileStream($tmpPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $outStream.Write($newHdr, 0, 16)
    $outStream.Write($newJsonBytes, 0, $newJsonBytes.Length)
    if ($padLen -gt 0) {
      $padBytes = New-Object byte[] $padLen
      $outStream.Write($padBytes, 0, $padLen)
    }

    $inStream.Position = $dataStart
    $copyBuf = New-Object byte[] $blockSize
    $remaining = $basePayloadLen
    while ($remaining -gt 0) {
      $toRead = [int][Math]::Min([int64]$blockSize, $remaining)
      $readCount = $inStream.Read($copyBuf, 0, $toRead)
      if ($readCount -le 0) { throw "Unexpected EOF while streaming ASAR payload." }
      $outStream.Write($copyBuf, 0, $readCount)
      $remaining -= $readCount
    }

    $outStream.Write($newHtmlBytes, 0, $newHtmlBytes.Length)
    $outStream.Flush($true)
    $outStream.Dispose()
    $outStream = $null

    $inStream.Dispose()
    $inStream = $null

    Move-FileAtomically -TempPath $tmpPath -DestPath $DestAsar
    return $DestAsar
  } catch {
    if ($null -ne $outStream) {
      try { $outStream.Dispose() } catch { }
      $outStream = $null
    }
    try {
      if ([System.IO.File]::Exists($tmpPath)) {
        [void](Test-IsReparsePoint $tmpPath)
        [System.IO.File]::Delete($tmpPath)
      }
    } catch { }
    throw
  } finally {
    if ($null -ne $sha) { try { $sha.Dispose() } catch { } }
    if ($null -ne $outStream) { try { $outStream.Dispose() } catch { } }
    if ($null -ne $inStream) { try { $inStream.Dispose() } catch { } }
  }
}

function Copy-SafeRuntimeTree([string]$SourceDir, [string]$DestDir, [string[]]$ExcludeNames = @()) {
  [void](Test-IsReparsePoint $SourceDir)
  if (Test-Path -LiteralPath $DestDir) {
    [void](Test-IsReparsePoint $DestDir)
  } else {
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    [void](Test-IsReparsePoint $DestDir)
  }
  foreach ($item in (Get-ChildItem -LiteralPath $SourceDir -Force)) {
    $skip = $false
    foreach ($ex in $ExcludeNames) {
      if ($item.Name -ieq $ex) { $skip = $true; break }
    }
    if ($skip) { continue }
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
    $targetPath = Join-Path $DestDir $item.Name
    if ($item.PSIsContainer) {
      Copy-SafeRuntimeTree -SourceDir $item.FullName -DestDir $targetPath
    } else {
      try {
        [void](Test-IsReparsePoint $targetPath)
        if ([System.IO.File]::Exists($targetPath)) {
          $tAttr = [System.IO.File]::GetAttributes($targetPath)
          if (($tAttr -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
            [System.IO.File]::SetAttributes($targetPath, ($tAttr -band (-bnot [System.IO.FileAttributes]::ReadOnly)))
          }
        }
      } catch [System.IO.FileNotFoundException], [System.IO.DirectoryNotFoundException] {
      }
      [System.IO.File]::Copy($item.FullName, $targetPath, $true)
    }
  }
}

function Ensure-PatchedClaudeRuntime([string]$SourceExe, [string]$ChatFont) {
  if ([string]::IsNullOrWhiteSpace($ChatFont) -or [string]::IsNullOrWhiteSpace($SourceExe)) { return $SourceExe }
  $slug = ($ChatFont.Trim().ToLowerInvariant() -replace '[^a-z0-9_-]', '')
  if ([string]::IsNullOrWhiteSpace((Get-ChatFontInjectionMarkup $slug))) { return $SourceExe }
  if (-not (Test-Path -LiteralPath $SourceExe)) { return $SourceExe }

  $srcAppDir = Split-Path -Parent $SourceExe
  $pkgDir = Split-Path -Parent $srcAppDir
  $srcResDir = Join-Path $srcAppDir 'resources'
  $srcIon = Join-Path $srcResDir 'ion-dist.asar'
  if (-not (Test-Path -LiteralPath $srcIon)) { return $SourceExe }

  [void](Test-IsReparsePoint $SourceExe)
  [void](Test-IsReparsePoint $srcAppDir)
  [void](Test-IsReparsePoint $pkgDir)
  [void](Test-IsReparsePoint $srcResDir)
  [void](Test-IsReparsePoint $srcIon)

  $ionInfo = Get-Item -LiteralPath $srcIon -Force
  $pkgLeaf = (Split-Path -Leaf $pkgDir) -replace '[^A-Za-z0-9._-]', '_'
  $cacheKey = [ordered]@{
    schemaVersion    = 'v1'
    pkgName          = $pkgLeaf
    ionSize          = [int64]$ionInfo.Length
    ionMtimeUtcTicks = [int64]$ionInfo.LastWriteTimeUtc.Ticks
    chatFont         = $slug
  }

  if (Test-Path -LiteralPath $HomeRoot) { [void](Test-IsReparsePoint $HomeRoot) }
  $rtRoot = Join-Path $HomeRoot 'runtime'
  if (Test-Path -LiteralPath $rtRoot) { [void](Test-IsReparsePoint $rtRoot) }
  $rtPkgDir = Join-Path $rtRoot "$($cacheKey.pkgName)_$slug"
  if (Test-Path -LiteralPath $rtPkgDir) { [void](Test-IsReparsePoint $rtPkgDir) }
  $rtAppDir = Join-Path $rtPkgDir 'app'
  $rtResDir = Join-Path $rtAppDir 'resources'
  $rtExe = Join-Path $rtAppDir (Split-Path -Leaf $SourceExe)
  $rtIon = Join-Path $rtResDir 'ion-dist.asar'
  $manifestPath = Join-Path $rtPkgDir '.patch-manifest.json'

  if ((Test-Path -LiteralPath $manifestPath) -and (Test-Path -LiteralPath $rtExe) -and (Test-Path -LiteralPath $rtIon)) {
    [void](Test-IsReparsePoint $rtAppDir)
    [void](Test-IsReparsePoint $rtResDir)
    [void](Test-IsReparsePoint $manifestPath)
    [void](Test-IsReparsePoint $rtExe)
    [void](Test-IsReparsePoint $rtIon)
    try {
      $m = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
      if (
        $null -ne $m -and
        ([string]$m.schemaVersion -eq [string]$cacheKey.schemaVersion) -and
        ([string]$m.pkgName -eq [string]$cacheKey.pkgName) -and
        ([int64]$m.ionSize -eq [int64]$cacheKey.ionSize) -and
        ([int64]$m.ionMtimeUtcTicks -eq [int64]$cacheKey.ionMtimeUtcTicks) -and
        ([string]$m.chatFont -eq [string]$cacheKey.chatFont)
      ) {
        return $rtExe
      }
    } catch { }
  }

  New-Item -ItemType Directory -Force -Path $rtResDir | Out-Null
  [void](Test-IsReparsePoint $rtRoot)
  [void](Test-IsReparsePoint $rtPkgDir)
  [void](Test-IsReparsePoint $rtAppDir)
  [void](Test-IsReparsePoint $rtResDir)

  if (Test-Path -LiteralPath $manifestPath) {
    [void](Test-IsReparsePoint $manifestPath)
    [System.IO.File]::Delete($manifestPath)
  }

  Copy-SafeRuntimeTree -SourceDir $srcAppDir -DestDir $rtAppDir -ExcludeNames @('resources')
  Copy-SafeRuntimeTree -SourceDir $srcResDir -DestDir $rtResDir -ExcludeNames @('ion-dist.asar')
  [void](Update-AsarIndexHtmlFontPatch -SourceAsar $srcIon -DestAsar $rtIon -ChatFont $slug)

  $tmpManifest = "$manifestPath.tmp.$PID"
  try {
    try {
      [void](Test-IsReparsePoint $tmpManifest)
      if ([System.IO.File]::Exists($tmpManifest)) { [System.IO.File]::Delete($tmpManifest) }
    } catch [System.IO.FileNotFoundException], [System.IO.DirectoryNotFoundException] {
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $manifestBytes = $utf8NoBom.GetBytes(($cacheKey | ConvertTo-Json -Compress))
    [System.IO.File]::WriteAllBytes($tmpManifest, $manifestBytes)
    Move-FileAtomically -TempPath $tmpManifest -DestPath $manifestPath
  } catch {
    try {
      if ([System.IO.File]::Exists($tmpManifest)) {
        [void](Test-IsReparsePoint $tmpManifest)
        [System.IO.File]::Delete($tmpManifest)
      }
    } catch { }
    throw
  }

  return $rtExe
}

function Write-LaunchAudit($inst, $ok, $detail) {
  # 启动审计：每次 launch 一行结论。Claude 的失败可以是完全静默的（argv 守卫直接
  # exit(1)，不写 main.log、不留 Crashpad 报告），没有这条日志就只能靠人肉猜。
  try {
    $path = Join-Path $HomeRoot 'launch-audit.log'
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $state = if ($ok) { 'OK  ' } else { 'FAIL' }
    $lines = @("$stamp  $state  $($inst.id)")
    if (-not $ok -and $detail) { foreach ($ln in ($detail -split "`n")) { $lines += "        $ln" } }
    Add-Content -Path $path -Value $lines -Encoding utf8
    $all = @(Get-Content -Path $path -ErrorAction SilentlyContinue)
    if ($all.Count -gt 400) { $all | Select-Object -Last 300 | Set-Content -Path $path -Encoding utf8 }
  } catch { }
}

function Get-LaunchFailureReport($inst, $launchedExe, $pkgExe, $launchArgs) {
  # 失败取证：用官方 exe 复跑一次（强制独立 --user-data-dir，绝不碰真实实例），
  # 9 秒内退出就读 stderr，据此区分三类原因：
  #   被守卫拒绝 / 参数以外的崩溃 / 参数没问题（问题在补丁 exe 或启动通道）。
  $out = @()
  $ver = try { (Get-ClaudePackage).Version.ToString() } catch { 'unknown' }
  $out += "version  : $ver"
  $out += "exe      : $launchedExe"
  $out += "args     : $($launchArgs -join ' ')"
  $verdict = 'unknown'
  if (Test-Path $pkgExe) {
    $diagDir = Join-Path $HomeRoot ('.diag-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $diagArgs = @($launchArgs | Where-Object { $_ -notmatch '^--user-data-dir' })
    $diagArgs = @("--user-data-dir=`"$diagDir`"") + $diagArgs
    $proc = $null
    try {
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = $pkgExe
      $psi.Arguments = ($diagArgs -join ' ')
      $psi.UseShellExecute = $false
      $psi.RedirectStandardError = $true
      $psi.RedirectStandardOutput = $true
      $psi.CreateNoWindow = $true
      $proc = [System.Diagnostics.Process]::Start($psi)
      $errTask = $proc.StandardError.ReadToEndAsync()
      $null = $proc.StandardOutput.ReadToEndAsync()
      if ($proc.WaitForExit(9000)) {
        $txt = ''
        try { $txt = $errTask.Result } catch { }
        $first = ($txt -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1
        $code = $proc.ExitCode
        if ($txt -match 'refusing to start') {
          $verdict = "ARGV-GUARD 官方 exe 同样被拒（exit $code）：$first"
        } elseif ($code -ne 0) {
          $verdict = "CRASH exit=$code，stderr 首行：$first"
        } elseif ($first) {
          $verdict = "LEGIT exit=0 未被守卫拒绝（参数合法）；stderr 有非致命输出：$first"
        } else {
          $verdict = "LEGIT exit=0 未被守卫拒绝（参数合法），stderr 为空"
        }
        Remove-Item $diagDir -Recurse -Force -ErrorAction SilentlyContinue
      } else {
        $verdict = "DIAG-ALIVE 参数与官方 exe 均正常（诊断实例 PID $($proc.Id) 仍在运行），故障出在启动通道 / 补丁 exe / 隔离环境"
      }
    } catch { $verdict = "DIAG-FAIL 诊断启动失败：$($_.Exception.Message)" }
  } else { $verdict = "NO-EXE 找不到 $pkgExe" }
  $out += "verdict  : $verdict"
  $out -join "`n"
}

# 2026-11-02: Claude 4.4212+ 的 argv 守卫黑名单（app.asar 内 NY 常量，前缀匹配）。
# 官方每次扩表，我们必然慢一拍 —— 所以这里只做零成本的预防性过滤，
# 真正的兜底是启动失败后的 Find-BlockedSwitch 探测 + 自动重试。
$script:ClaudeBlockedSwitches = @(
  'remote-debugging-port', 'remote-debugging-pipe', 'ignore-certificate-errors',
  'host-resolver-rules', 'host-rules', 'disable-web-security', 'log-net-log',
  'net-log-capture-mode', 'ssl-key-log-file', 'renderer-cmd-prefix',
  'utility-cmd-prefix', 'gpu-launcher', 'zygote-cmd-prefix',
  'ppapi-plugin-launcher', 'nacl-loader-cmd-prefix', 'browser-subprocess-path'
)

function Remove-BlockedSwitches($launchArgs) {
  $kept = @(); $dropped = @()
  foreach ($a in $launchArgs) {
    if ($a -match '^--?') {
      $name = (($a -replace '^--?', '') -split '=')[0].ToLowerInvariant()
      if ($script:ClaudeBlockedSwitches | Where-Object { $name.StartsWith($_) }) { $dropped += $a; continue }
    }
    $kept += $a
  }
  [pscustomobject]@{ Args = @($kept); Dropped = @($dropped) }
}

function Find-BlockedSwitch($pkgExe, $launchArgs) {
  # 未知元凶探测：逐个注入单一开关，被守卫拒绝即锁定该开关。仅在前缀过滤没兜住
  # （官方新增了黑名单项）时调用，代价是每个候选一次 3.5s 的探针启动。
  $cands = @($launchArgs | Where-Object { $_ -match '^--' -and $_ -notmatch '^--user-data-dir' })
  foreach ($c in $cands) {
    $probe = ($c -split '=')[0]
    $dir = Join-Path $HomeRoot ('.probe-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    try {
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = $pkgExe
      $psi.Arguments = "--user-data-dir=`"$dir`" $probe=1 --lang=en"
      $psi.UseShellExecute = $false
      $psi.RedirectStandardError = $true
      $psi.RedirectStandardOutput = $true
      $psi.CreateNoWindow = $true
      $p = [System.Diagnostics.Process]::Start($psi)
      $et = $p.StandardError.ReadToEndAsync()
      $null = $p.StandardOutput.ReadToEndAsync()
      if ($p.WaitForExit(3500)) {
        $txt = ''
        try { $txt = $et.Result } catch { }
        if ($txt -match 'refusing to start') { return $c }
      } else { try { $p.Kill() } catch { } }
    } catch { } finally {
      Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
  $null
}

function Invoke-Launch($i, [string]$Url, [switch]$NoAgent, [switch]$Minimized, [switch]$Show, [switch]$NoAdaptive) {
  $pkg = Get-ClaudePackage
  $pkgExe = Join-Path $pkg.InstallLocation 'app\Claude.exe'
  $exe = $pkgExe
  # 2026-10-17: direct CreateProcess on the WindowsApps exe started failing with
  # "Access is denied" (ACLs unchanged - policy tightening on direct package-exe
  # launches). The app execution alias is the sanctioned activation path and
  # forwards the command line unchanged, so prefer it when present.
  $aliasExe = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\claude-desktop-msstore.exe'
  if (Test-Path $aliasExe) { $exe = $aliasExe }
  $chatFont = if ($i.PSObject.Properties['chatFont'] -and $i.chatFont) { ([string]$i.chatFont).Trim().ToLowerInvariant() } else { '' }
  if ($chatFont) {
    $patchedExe = Ensure-PatchedClaudeRuntime -SourceExe $pkgExe -ChatFont $chatFont
    if ($patchedExe -and $patchedExe -ne $pkgExe) { $exe = $patchedExe }
  }
  $data = Get-DataDir $i
  $args_ = @()
  if ($Url) { $args_ += "`"$Url`"" }
  if (-not (Get-Roots $i)) { try { Apply-PendingSettings $i } catch { } }      # settings changed elsewhere while this instance was closed
  $savedNodeOpts = $env:NODE_OPTIONS
  try {
    if (-not ($i.kind -eq 'official' -and $i.id -eq 'official')) {
      Assert-ProfileDataIdentity $data $i.id | Out-Null
    }
    $shieldPath = Write-ShieldScript $data

    $effectiveTz   = if ($i.PSObject.Properties['timezone'] -and $i.timezone) { [string]$i.timezone } else { '' }
    $effectiveLang = if ($i.PSObject.Properties['lang'] -and $i.lang -and $i.lang -ne 'auto') { [string]$i.lang } else { '' }
    $startupIp     = ''

    if ($i.proxy) {
      $geo = Test-ProxyGeoConsensus $i $data
      if ($geo) {
        if ($geo.verifiedIp) { $startupIp = [string]$geo.verifiedIp }
        if (-not $effectiveTz -or $effectiveTz -eq 'auto') { $effectiveTz = [string]$geo.timezone }
        if (-not $effectiveLang -or $effectiveLang -eq 'auto') { $effectiveLang = [string]$geo.lang }
      }
    }

    Ensure-ProfilePreferences $data $effectiveLang | Out-Null

    if ($effectiveTz -and $effectiveTz -ne 'auto') {
      $env:TZ = $effectiveTz
    } else {
      [Environment]::SetEnvironmentVariable('TZ', $null, 'Process')
    }
    if ($i.proxy) {
      $env:HTTP_PROXY = $i.proxy; $env:HTTPS_PROXY = $i.proxy; $env:ALL_PROXY = $i.proxy
      $env:CLAUDE_MULTI_PROXY_URL = $i.proxy
      if ($startupIp) { $env:CLAUDE_MULTI_STARTUP_IP = $startupIp }
      $env:CLAUDE_MULTI_EXIT_POLICY = if ($i.PSObject.Properties['proxyExitPolicy'] -and $i.proxyExitPolicy) { [string]$i.proxyExitPolicy } elseif ($startupIp) { 'block' } else { 'warn' }
      $env:CLAUDE_MULTI_MONITOR_INTERVAL_MS = if ($i.PSObject.Properties['monitorIntervalMs'] -and $i.monitorIntervalMs) { [string]$i.monitorIntervalMs } else { '300000' }
      $env:CLAUDE_MULTI_USER_DATA_DIR = $data
      $reqOpt = "--require `"$shieldPath`""
      $env:NODE_OPTIONS = if ($env:NODE_OPTIONS) { "$($env:NODE_OPTIONS) $reqOpt" } else { $reqOpt }
    } else {
      [Environment]::SetEnvironmentVariable('HTTP_PROXY', $null, 'Process')
      [Environment]::SetEnvironmentVariable('HTTPS_PROXY', $null, 'Process')
      [Environment]::SetEnvironmentVariable('ALL_PROXY', $null, 'Process')
    }
    if ($i.kind -eq 'official') {
      if ($i.id -eq 'official') {
        if ($i.isolate -ne $false) { $env:LOCALAPPDATA = Initialize-OfficialHome }
      } else {
        if ($i.isolate -ne $false) { $env:LOCALAPPDATA = Initialize-OfficialHome $i.id }
        New-Item -ItemType Directory -Force $data | Out-Null
        $cfgLib = Join-Path $data 'configLibrary'
        if (Test-Path $cfgLib) { Remove-Item -Path $cfgLib -Recurse -Force }
        # Sync claude_desktop_config.json (MCP tools, Nowledge-mem)
        $canonicalCfg = Join-Path $OfficialDir 'claude_desktop_config.json'
        $instCfg = Join-Path $data 'claude_desktop_config.json'
        if ((Test-Path $canonicalCfg) -and -not (Test-Path $instCfg)) {
          try { & cmd.exe /c mklink /H "`"$instCfg`"" "`"$canonicalCfg`"" | Out-Null }
          catch { Copy-Item -Path $canonicalCfg -Destination $instCfg -Force }
        }
        if ((Read-Config).settings.syncSessions -ne $false) {
          foreach ($sessDir in 'claude-code-sessions', 'local-agent-mode-sessions') {
            $realSess = Join-Path $OfficialDir $sessDir
            $linkSess = Join-Path $data $sessDir
            if ((Test-Path $realSess) -and -not (Test-Path $linkSess)) {
              & cmd.exe /c mklink /J "`"$linkSess`"" "`"$realSess`"" | Out-Null
            }
          }
        }
        $args_ = @("--user-data-dir=`"$data`"") + $args_
        if ($i.proxy) {
          $cleanProxy = $i.proxy -replace '://[^/@\s]+@', '://' -replace '^[^/@\s]+@', ''
          $args_ += "--proxy-server=`"$cleanProxy`""
        }
      }
    } else {
      $primary = ($data -eq $SourceDir)
      $profileTime = if ($primary) { Get-NewestWrite (Join-Path $SourceDir 'configLibrary') }
                     else { $env:LOCALAPPDATA = Get-FakeLocal $i; New-Item -ItemType Directory -Force $data | Out-Null; Sync-Profile $i $data }
      # a running window is never killed here: a changed profile applies on the next restart (Restart button / quit and reopen)
      $args_ = @("--user-data-dir=`"$data`"") + $args_
    }
    # 2026-10-20: Chromium/Electron 的 WebRTC 默认走裸 UDP，完全绕过 --proxy-server。
    # 强制 WebRTC UDP 策略以阻止真实 IP 泄漏。
    # 同时补 official 分支缺失的 --proxy-server 并去除嵌入的凭据（Chromium 命令行不接受 user:pass）。
    if ($effectiveLang) {
      $args_ += "--lang=$effectiveLang"
    }
    if ($i.proxy) {
      if (-not (($args_ -join ' ') -match '--proxy-server')) {
        $cleanProxy = $i.proxy -replace '://[^/@\s]+@', '://' -replace '^[^/@\s]+@', ''
        $args_ += "--proxy-server=`"$cleanProxy`""
      }
      # 2026-11-01: Claude Desktop 4.4212.0.0 起在主进程启动时扫描 process.argv，
      # 命中黑名单即以 "Claude: refusing to start - a debugging or network-override
      # switch is present on the command line." exit(1)。黑名单（app.asar 内 NY 常量，
      # 前缀匹配 startsWith）：
      #   remote-debugging-port / remote-debugging-pipe / ignore-certificate-errors /
      #   host-resolver-rules / host-rules / disable-web-security / log-net-log /
      #   net-log-capture-mode / ssl-key-log-file / renderer-cmd-prefix /
      #   utility-cmd-prefix / gpu-launcher / zygote-cmd-prefix /
      #   ppapi-plugin-launcher / nacl-loader-cmd-prefix / browser-subprocess-path
      # --proxy-server 不在名单内（官方支持自定义代理），故仅移除
      # --host-resolver-rules。隔离强度不降级：Chromium 在 HTTP 代理模式下由代理侧
      # 解析域名、不发本地 DNS 查询。QUIC 由 --disable-quic 关掉；
      # WebRTC 的裸 UDP 命令行关不住，改由 Ensure-UdpLeakGuard 在防火墙层封堵（见下）。
      $args_ += '--disable-quic'
    }
    # 2026-11-03 修正：这里原本还加了
    #   --force-webrtc-ip-handling-policy / --dns-prefetch-disable /
    #   --webrtc-ip-handling-policy=disable_non_proxied_udp / --enforce-webrtc-ip-permission-check
    # 四个开关，逐个在 Claude.exe 里 `grep -a` 核实后确认**前两个根本不存在**（Chromium 156 已移除，
    # 写了只是静默忽略），后两个的 switch 字符串在二进制里也搜不到（Electron 未编译进去），
    # 而 disable_non_proxied_udp 只以偏好值的形式存在于 app.asar，靠 Claude 自己写 Preferences，
    # 且不下发给 renderer。也就是说这四条全是安慰剂，留着只会让人误以为已经封住了。
    # 真正的封堵在 Ensure-UdpLeakGuard（防火墙按 exe 阻断出站 UDP），启动前调用。
    # 若将来某个 Electron 版本真的编译进了 webrtc-ip-handling-policy，可以用
    #   grep -a -o "webrtc-ip-handling-policy" Claude.exe
    # 复核后再加回来 —— 判断依据是二进制里有没有这个字符串，而不是文档里写没写。
    $udpTarget = if ($exe -eq $aliasExe) { $pkgExe } else { $exe }
    if ((Read-Config).settings.udpGuard -ne $false) {
      try { Ensure-UdpLeakGuard $i.id $udpTarget | Out-Null } catch { }
    }
    $filt = Remove-BlockedSwitches $args_
    if ($filt.Dropped.Count -gt 0) {
      $args_ = $filt.Args
      try {
        Add-Content -Path (Join-Path $HomeRoot 'launch-audit.log') -Encoding utf8 -Value ("{0}  DROP  {1}  blocked=[{2}]" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $i.id, ($filt.Dropped -join ' '))
      } catch { }
    }
    if ($Minimized) { [void][ShellProp]::StartMinNoActivate($exe, ($args_ -join ' ')) }
    elseif ($args_.Count) { Start-Process $exe -ArgumentList $args_ } else { Start-Process $exe }
  } finally {
    $env:LOCALAPPDATA = $RealLocal
    $env:NODE_OPTIONS = $savedNodeOpts
    [Environment]::SetEnvironmentVariable('TZ', $null, 'Process')
    [Environment]::SetEnvironmentVariable('HTTP_PROXY', $null, 'Process')
    [Environment]::SetEnvironmentVariable('HTTPS_PROXY', $null, 'Process')
    [Environment]::SetEnvironmentVariable('ALL_PROXY', $null, 'Process')
    [Environment]::SetEnvironmentVariable('CLAUDE_MULTI_PROXY_URL', $null, 'Process')
    [Environment]::SetEnvironmentVariable('CLAUDE_MULTI_STARTUP_IP', $null, 'Process')
    [Environment]::SetEnvironmentVariable('CLAUDE_MULTI_EXIT_POLICY', $null, 'Process')
    [Environment]::SetEnvironmentVariable('CLAUDE_MULTI_MONITOR_INTERVAL_MS', $null, 'Process')
    [Environment]::SetEnvironmentVariable('CLAUDE_MULTI_USER_DATA_DIR', $null, 'Process')
  }
  if (-not $NoAgent) { Start-Agent }
  # 启动自检（2026-11-02）：原实现只在 -Show 时轮询窗口，失败则完全静默 —— 用户侧
  # 表现就是"双击没反应"，且 Claude 的拒绝启动不留任何日志。现在无条件等进程出现，
  # 拿不到就取证 + 落审计 + 抛出可读错误。
  if (-not $Minimized) {
    $root = $null
    for ($k = 0; $k -lt 48; $k++) {
      $r = @(Get-Roots $i) | Select-Object -First 1
      if ($r) { $root = $r; break }
      Start-Sleep -Milliseconds 250
    }
    if (-not $root) {
      $report = Get-LaunchFailureReport $i $exe $pkgExe $args_
      Write-LaunchAudit $i $false $report
      if (-not $NoAdaptive -and $report -match 'ARGV-GUARD') {
        $culprit = Find-BlockedSwitch $pkgExe $args_
        if ($culprit) {
          Write-LaunchAudit $i $false ("auto-adapt: dropping [$culprit] and retrying - add it to `$script:ClaudeBlockedSwitches")
          Invoke-Launch $i $Url -NoAgent:$NoAgent -Minimized:$Minimized -Show:$Show -NoAdaptive
          return
        }
        Write-LaunchAudit $i $false 'auto-adapt: ARGV-GUARD reproduced but no single argv switch was identified as the culprit'
      }
      throw ("instance '$($i.id)' failed to start. diagnosis written to $HomeRoot\launch-audit.log`n`n$report")
    }
    Write-LaunchAudit $i $true ''
    if ($Show) {       # the user asked for this window: bring it up even if it was sitting minimised
      for ($k = 0; $k -lt 40; $k++) {
        $p = Get-Process -Id $root.ProcessId -ErrorAction SilentlyContinue
        if ($p -and $p.MainWindowHandle -ne 0) { [ShellProp]::Restore($p.MainWindowHandle); [void][ShellProp]::Foreground($p.MainWindowHandle); break }
        Start-Sleep -Milliseconds 250
      }
    }
  }
}

# ---------------------------------------------------------------- icons & shortcuts
function Update-Icons($instances, [switch]$Force) {
  $pkg = Get-ClaudePackage; $pal = Get-Palettes; $base = $null
  foreach ($i in $instances) {
    $path = Get-IconPath $i
    if ((Test-Path $path) -and -not $Force) { continue }
    if (-not $base) { $base = Get-IconBase $pkg }
    if ($i.palette -eq 'official' -or ($i.id -eq 'official' -and -not $i.palette)) { Save-Ico $base $path }
    else { Save-Ico (Convert-IconBase $base (Resolve-Palette $i.palette $pal)) $path }
    "icon: $path"
  }
}
function Set-Link($path, $i) {
  $s = (New-Object -ComObject WScript.Shell).CreateShortcut($path)
  $s.TargetPath = $Wscript; $s.Arguments = "//B //Nologo `"$Root\run.vbs`" $($i.id)"
  $s.IconLocation = (Get-IconPath $i) + ',0'; $s.WorkingDirectory = $Root; $s.Description = $i.name
  $s.Save(); [ShellProp]::SetLinkAumid($path, (Get-Aumid $i))
  "shortcut: $path"
}
function Get-LegacyNames($i) { if ($i.id -eq '3p') { @('Claude (3P)') } else { @() } }
function Update-PinnedLinks($i) {   # rewire already-pinned taskbar shortcuts so the pin and the windows share one button
  foreach ($n in @($i.name) + (Get-LegacyNames $i)) { $l = Join-Path $PinDir "$n.lnk"; if (Test-Path $l) { Set-Link $l $i } }
}
function Get-OfficialLinks {
  @((Join-Path $PinDir 'Claude.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Claude.lnk'),
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Claude.lnk",
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Anthropic\Claude.lnk")
}
function Install-All([switch]$Force) {
  $inst = @((Read-Config).instances)
  Update-Icons $inst -Force:$Force
  foreach ($i in $inst) {
    if ($i.kind -eq 'official' -and $i.id -eq 'official') {
      $links = @(Get-OfficialLinks | Where-Object { Test-Path $_ })
      if (-not $links) { $links = @(Join-Path ([Environment]::GetFolderPath('Desktop')) 'Claude.lnk') }
      foreach ($l in $links) { Set-Link $l $i }
    } else { Set-Link (Get-DesktopLink $i) $i; Update-PinnedLinks $i }
  }
  # manager (GUI) shortcut
  $mi = [pscustomobject]@{ id = 'manager'; name = 'Claude Multi Manager'; kind = 'tool'; palette = 'violet' }
  Update-Icons @($mi) -Force:$Force
  $ml = Join-Path ([Environment]::GetFolderPath('Desktop')) ($mi.name + '.lnk')
  $s = (New-Object -ComObject WScript.Shell).CreateShortcut($ml)
  $s.TargetPath = $Wscript; $s.Arguments = "//B //Nologo `"$Root\run.vbs`" --gui"
  $s.IconLocation = (Get-IconPath $mi) + ',0'; $s.WorkingDirectory = $Root; $s.Description = $mi.name; $s.Save()
  "shortcut: $ml"
  Register-Protocol
  & ie4uinit.exe -show 2>$null
}

# ---------------------------------------------------------------- claude:// routing
function Register-RestartProtocol {      # claudemulti://restart/<id>  (target of the "Reload now" toast button)
  $k = 'HKCU:\Software\Classes\claudemulti'
  $cmd = "`"$Wscript`" //B //Nologo `"$Root\run.vbs`" --restart `"%1`""
  $cur = try { (Get-ItemProperty "$k\shell\open\command" -ErrorAction Stop).'(default)' } catch { '' }
  if ($cur -eq $cmd) { return }
  New-Item "$k\shell\open\command" -Force | Out-Null
  Set-ItemProperty $k -Name '(default)' -Value 'URL:Claude Multi'; Set-ItemProperty $k -Name 'URL Protocol' -Value ''
  Set-ItemProperty "$k\shell\open\command" -Name '(default)' -Value $cmd
}
function Register-Protocol {
  Register-RestartProtocol
  foreach ($s in 'claude') {
    $k = "HKCU:\Software\Classes\$s"
    $cmd = "`"$Wscript`" //B //Nologo `"$Root\run.vbs`" --url `"%1`""
    $cur = try { (Get-ItemProperty "$k\shell\open\command" -ErrorAction Stop).'(default)' } catch { '' }
    if ($cur -eq $cmd) { continue }
    New-Item "$k\shell\open\command" -Force | Out-Null
    Set-ItemProperty $k -Name '(default)' -Value 'URL:Claude'
    Set-ItemProperty $k -Name 'URL Protocol' -Value ''
    Set-ItemProperty "$k\shell\open\command" -Name '(default)' -Value $cmd
  }
}
function Invoke-RouteUrl([string]$Url) {
  if ($Url -notmatch '^claude(-desktop)?://[^\s"]+$') { throw 'Refusing non-claude URL' }
  $cfg = Read-Config; $all = @($cfg.instances)
  $running = @(Get-ClaudeMains | ForEach-Object { Find-InstanceOf $_ $all } | Where-Object { $_ })
  $want = $cfg.settings.protocol
  if ($want -eq 'last') { $want = (Read-State).lastActive }
  $target = $all | Where-Object { $_.id -eq $want } | Select-Object -First 1
  if (-not $target) { $target = $running | Select-Object -First 1 }
  if (-not $target) { $target = $all | Where-Object kind -eq 'official' | Select-Object -First 1 }
  New-Item -ItemType Directory -Force $StateDir | Out-Null
  Add-Content (Join-Path $StateDir 'route.log') ('{0} -> {1} (want={2}, running={3})' -f (Get-Date -Format s), $target.id, $want, (($running | ForEach-Object id) -join ','))
  Invoke-Launch $target $Url -Show
}

# ---------------------------------------------------------------- session sync
# The app reads its session list only at start-up (no file watcher, no reload hook), so keeping instances in sync takes two steps:
#  1) mirror every session file newest-wins into every instance's store (this section), and
#  2) silently restart a stale instance in the background when it is idle and not in use (Invoke-LiveRefresh below).
$script:CopiedStamp = @{}       # destination path -> mtime ticks we wrote (lets us tell our copies from the app's own writes)
$script:StaleSince  = @{}       # instance id -> time of the last file mirrored into its store
$script:LastRestart = @{}
$script:Cpu         = @{}

function Get-StoreRoot($i) { Get-DataDir $i }
function Get-SessionMeta([string]$path) {   # the fields a user sees in the list: pin/star, archive, title
  $txt = [IO.File]::ReadAllText($path); $m = ''
  foreach ($k in 'isStarred', 'isArchived') { if ($txt -match "`"$k`":(true|false)") { $m += "$k=$($Matches[1]);" } }
  if ($txt -match '"title":"((?:[^"\\]|\\.)*)"') { $m += 'title=' + $Matches[1] }
  $m
}
function Get-SessionFolders {
  foreach ($i in (Read-Config).instances) {
    $cs = Join-Path (Get-StoreRoot $i) 'claude-code-sessions'
    if (-not (Test-Path $cs)) { continue }
    foreach ($a in [IO.Directory]::GetDirectories($cs)) { foreach ($o in [IO.Directory]::GetDirectories($a)) { if ($o -notmatch '-backup$') { [pscustomobject]@{ Path = $o; Id = $i.id } } } }
  }
}
function Backup-Sessions {   # rolling: one snapshot per calendar day, the newest 7 are kept (session files are never deleted)
  $root = Join-Path $StateDir 'backup-sessions'
  $dst = Join-Path $root ('daily-' + (Get-Date -Format yyyyMMdd))
  $stores = 0
  if (-not (Test-Path $dst)) {
    New-Item -ItemType Directory -Force $dst | Out-Null
    $n = 0
    foreach ($i in (Read-Config).instances) {
      $cs = Join-Path (Get-StoreRoot $i) 'claude-code-sessions'
      if (Test-Path $cs) { robocopy $cs (Join-Path $dst ('s' + $n++)) /E /XJ /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null; $stores++ }
    }
  }
  $keep = @(Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'daily-*' } | Sort-Object Name -Descending)
  if ($stores) { try { [IO.File]::WriteAllText((Join-Path $dst '_meta.txt'), ((Get-Date -Format s) + "  stores=" + $stores), (New-Object Text.UTF8Encoding $false)) } catch { } }
  foreach ($d in @($keep | Select-Object -Skip 7)) { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue }
}
# Newest-wins mirror of every session file into every account/org folder of every instance (never deletes).
function Invoke-SessionSync {
  $folders = @(Get-SessionFolders)
  if ($folders.Count -lt 2) { return 0 }
  $idx = @{}; $best = @{}
  foreach ($f in $folders) {
    $ix = [ShellProp]::Index($f.Path); $idx[$f.Path] = $ix
    foreach ($kv in $ix.GetEnumerator()) {
      if (-not $best.ContainsKey($kv.Key) -or $kv.Value -gt $best[$kv.Key].t) { $best[$kv.Key] = @{ p = [IO.Path]::Combine($f.Path, $kv.Key); t = $kv.Value } }
    }
  }
  $copied = 0; $slack = 10000000     # 1 s in ticks
  foreach ($f in $folders) {
    $ix = $idx[$f.Path]
    foreach ($n in @($best.Keys)) {
      $b = $best[$n]; $have = $ix.ContainsKey($n)
      if ($have -and $ix[$n] -ge $b.t - $slack) { continue }                       # up to date: the common case costs one dictionary lookup
      $dst = [IO.Path]::Combine($f.Path, $n)
      if ($dst -eq $b.p) { continue }
      try {
        $metaChanged = $false
        if ($have) { $metaChanged = ((Get-SessionMeta $dst) -ne (Get-SessionMeta $b.p)) }
        [IO.File]::Copy($b.p, $dst, $true); [IO.File]::SetLastWriteTimeUtc($dst, [DateTime]::new($b.t, 'Utc'))
        $script:CopiedStamp[$dst] = [IO.File]::GetLastWriteTimeUtc($dst).Ticks
        if (-not $have -or $metaChanged) { $script:StaleSince[$f.Id] = Get-Date }     # only a session the instance has never seen makes it stale (updates to known ones do not)
        $copied++
      } catch { }
    }
  }
  $copied
}
function Initialize-SessionStores {   # new instances start with the same session folders as the primary 3P store
  $src = Join-Path $SourceDir 'claude-code-sessions'
  if (-not (Test-Path $src)) { return }
  foreach ($i in (Read-Config).instances) {
    if ($i.kind -eq 'official' -or $i.id -eq '3p') { continue }
    $dst = Join-Path (Get-StoreRoot $i) 'claude-code-sessions'
    foreach ($a in [IO.Directory]::GetDirectories($src)) { foreach ($o in [IO.Directory]::GetDirectories($a)) {
      if ($o -notmatch '-backup$') { New-Item -ItemType Directory -Force (Join-Path (Join-Path $dst (Split-Path $a -Leaf)) (Split-Path $o -Leaf)) | Out-Null } } }
  }
}

# ---------------------------------------------------------------- live refresh (silent background restart of stale, idle instances)
function Get-Descendants([int]$rootPid, $procs) {
  $kids = @{}
  foreach ($p in $procs) { $k = [int]$p.ParentProcessId; if (-not $kids.ContainsKey($k)) { $kids[$k] = New-Object Collections.ArrayList }; [void]$kids[$k].Add($p) }
  $out = New-Object Collections.ArrayList; $q = New-Object Collections.Queue; $q.Enqueue($rootPid)
  while ($q.Count) { $x = $q.Dequeue(); if ($kids.ContainsKey($x)) { foreach ($c in $kids[$x]) { [void]$out.Add($c); $q.Enqueue([int]$c.ProcessId) } } }
  $out
}
function Test-InstanceBusy($i, $rootProc, $procs) {
  # 1) the app itself rewrote a session file in the last 45 s (a file we did not just mirror)
  $now = [datetime]::UtcNow
  $startedUtc = $rootProc.CreationDate.ToUniversalTime().AddSeconds(120)      # the app rewrites its starred sessions right after it starts: not 'work'
  $cs = Join-Path (Get-StoreRoot $i) 'claude-code-sessions'
  if (Test-Path $cs) {
    foreach ($f in [IO.Directory]::EnumerateFiles($cs, 'local_*.json', [IO.SearchOption]::AllDirectories)) {
      $t = [IO.File]::GetLastWriteTimeUtc($f)
      if (($now - $t).TotalSeconds -lt 45 -and $t -gt $startedUtc -and $script:CopiedStamp[$f] -ne $t.Ticks) { return $true }
    }
  }
  # 2) a non-Electron child (agent CLI, build tool, ...) burned CPU since the previous check
  foreach ($c in (Get-Descendants $rootProc.ProcessId $procs)) {
    if ($c.ExecutablePath -and $c.ExecutablePath -like '*\AnthropicPBC.Claude_*') { continue }
    try {
      $cpu = [Diagnostics.Process]::GetProcessById([int]$c.ProcessId).TotalProcessorTime.TotalSeconds
      $prev = $script:Cpu[[int]$c.ProcessId]; $script:Cpu[[int]$c.ProcessId] = $cpu
      if ($null -ne $prev -and ($cpu - $prev) -gt 0.5) { return $true }
    } catch { }
  }
  $false
}
$script:Relaunch = @{}
function Write-AgentLog([string]$m) { try { New-Item -ItemType Directory -Force $StateDir | Out-Null; Add-Content (Join-Path $StateDir 'agent.log') ("{0} {1}" -f (Get-Date -Format s), $m) } catch { } }
function Restart-Instance($i, $focusFix) {   # kill, wait until it is really gone, apply pending settings, start again (and verify in the agent loop)
  if (-not (@((Read-Config).instances) | Where-Object id -eq $i.id)) { return }
  $prev = [ShellProp]::ForegroundWindow()
  foreach ($r in @(Get-Roots $i)) { & taskkill.exe /F /T /PID $r.ProcessId | Out-Null }
  for ($k = 0; $k -lt 30; $k++) { if (-not @(Get-Roots $i)) { break }; Start-Sleep -Milliseconds 500 }
  Start-Sleep -Seconds 3                                        # let the single-instance lock of the old process go
  try { Apply-PendingSettings $i } catch { }
  Invoke-Launch $i -NoAgent -Minimized
  $script:Relaunch[$i.id] = @{ at = Get-Date; tries = 1 }
  if ($focusFix) { $focusFix[$i.id] = @{ prev = $prev; until = (Get-Date).AddSeconds(90); started = Get-Date; n = 0 } }
  Write-AgentLog "restarted '$($i.id)'"
}
# A window only knows the sessions that existed when it started. Stores can be shared through junctions (nothing is "copied" then),
# so staleness is judged per running process: session files it has never seen = files created after it started.
$script:Seen = @{}
$script:ToastAt = @{}
function Update-Staleness($i, $m) {
  $key = "$($i.id)|$($m.ProcessId)"
  $startUtc = $m.CreationDate.ToUniversalTime().AddSeconds(3)
  $all = New-Object 'Collections.Generic.HashSet[string]'
  foreach ($f in @(Get-SessionFolders | Where-Object Id -eq $i.id)) {
    foreach ($p in [IO.Directory]::EnumerateFiles($f.Path, 'local_*.json')) { [void]$all.Add([IO.Path]::GetFileName($p)) }
  }
  if (-not $script:Seen.ContainsKey($key)) {
    $known = New-Object 'Collections.Generic.HashSet[string]'
    foreach ($f in @(Get-SessionFolders | Where-Object Id -eq $i.id)) {
      foreach ($p in [IO.Directory]::EnumerateFiles($f.Path, 'local_*.json')) { if ([IO.File]::GetCreationTimeUtc($p) -le $startUtc) { [void]$known.Add([IO.Path]::GetFileName($p)) } }
    }
    $script:Seen[$key] = @{ known = $known; unknown = -1 }
  }
  $s = $script:Seen[$key]; $unknown = 0
  foreach ($n in $all) { if (-not $s.known.Contains($n)) { $unknown++ } }
  if ($unknown -gt 0 -and $unknown -ne $s.unknown) { $script:StaleSince[$i.id] = Get-Date }        # new session(s) arrived: restart the settle timer
  if ($unknown -eq 0 -and -not (Test-PendingSettings $i.id)) { $script:StaleSince.Remove($i.id) }    # nothing left to load
  $s.unknown = $unknown
  foreach ($k in @($script:Seen.Keys)) { if ($k -like "$($i.id)|*" -and $k -ne $key) { $script:Seen.Remove($k) } }   # forget old processes
}
$script:IdentApplied = @{}
function Set-InstanceIdentity($i, $m, $p) {
  if (($i.kind -eq 'official' -and $i.id -eq 'official') -or -not $p -or $p.MainWindowHandle -eq 0) { return }
  $ico = Get-IconPath $i; $stamp = if (Test-Path $ico) { (Get-Item $ico).LastWriteTimeUtc.Ticks } else { 0 }
  if ([ShellProp]::GetWindowAumid($p.MainWindowHandle) -ne (Get-Aumid $i) -or $script:IdentApplied[$m.ProcessId] -ne $stamp) {
    [void][ShellProp]::SetWindowIdentity($p.MainWindowHandle, (Get-Aumid $i), (Get-Shim $i), "$ico,0", $i.name)
    [ShellProp]::SetWindowIcon($p.MainWindowHandle, $ico); $script:IdentApplied[$m.ProcessId] = $stamp
    [void][ShellProp]::SetWindowText($p.MainWindowHandle, "Claude - $($i.name)")
  }
  [void][TrayIcon]::Apply([uint32]$m.ProcessId, $ico, $i.name)        # tray (notification area) icon + tooltip
}
function Invoke-FocusFix($focusFix, $mains, $all) {   # a silently restarted window stays minimised and never takes the focus
  foreach ($m in $mains) {
    $i = Find-InstanceOf $m $all; if (-not $i -or -not $focusFix.ContainsKey($i.id)) { continue }
    $ff = $focusFix[$i.id]
    if ((Get-Date) -gt $ff.until) { $focusFix.Remove($i.id); continue }
    $p = Get-Process -Id $m.ProcessId -ErrorAction SilentlyContinue
    if (-not $p -or $p.MainWindowHandle -eq 0) { continue }
    $h = $p.MainWindowHandle
    Set-InstanceIdentity $i $m $p                  # the window must leave the official taskbar group the moment it exists
    $age = ((Get-Date) - $ff.started).TotalSeconds
    if ($age -lt 12) {                                                         # only while the app is still starting up
      if ([ShellProp]::IsVisibleNotMinimized($h) -and $age -lt 8) { [ShellProp]::MinimizeNoActivate($h); $ff.n++ }
      if ([ShellProp]::ForegroundPid() -eq $m.ProcessId -and $ff.prev -ne [IntPtr]::Zero -and $age -lt 4) { [void][ShellProp]::Foreground($ff.prev) }
    }
    if ($age -ge 12) { $focusFix.Remove($i.id) }                               # from here on the window is the user's: no more interference
  }
}
function Invoke-LiveRefresh($cfg, $mains, [uint32]$fgPid, $focusFix) {
  if (-not $cfg.settings.liveRefresh) { return }
  $all = @($cfg.instances); $procs = $null
  foreach ($m in $mains) {
    $i = Find-InstanceOf $m $all; if (-not $i) { continue }
    if ($i.kind -eq 'official' -and -not $cfg.settings.refreshOfficial) { continue }
    try { Update-Staleness $i $m } catch { Write-AgentLog "staleness check failed: $_" }
    $since = $script:StaleSince[$i.id]; if (-not $since) { continue }
    if (((Get-Date) - $since).TotalSeconds -lt 8) { continue }                         # let the other instance finish writing
    if ($m.ProcessId -eq $fgPid -and [ShellProp]::IdleSeconds() -lt 90) {             # the window in use is never touched: offer a button instead
      $w = $script:ToastAt[$i.id]
      if ($cfg.settings.notifyReload -and (-not $w -or ((Get-Date) - $w).TotalMinutes -gt 15)) { $script:ToastAt[$i.id] = Get-Date; Show-ReloadToast $i ($script:Seen["$($i.id)|$($m.ProcessId)"].unknown) }
      continue
    }
    $last = $script:LastRestart[$i.id]; if ($last -and ((Get-Date) - $last).TotalSeconds -lt 120) { continue }
    if (-not $procs) { $procs = @(Get-CimInstance Win32_Process) }
    if (Test-InstanceBusy $i $m $procs) { continue }
    $script:StaleSince.Remove($i.id); $script:LastRestart[$i.id] = Get-Date
    Restart-Instance $i $focusFix
    return                                                                            # one restart per cycle
  }
}

function Invoke-Doctor {
  [CmdletBinding()]
  param()

  Write-Host "=== Claude Multi Doctor (Windows) ===" -ForegroundColor Cyan
  $passes = 0
  $warns  = 0
  $fails  = 0

  # 1. PowerShell version
  $psVer = $PSVersionTable.PSVersion
  if ($psVer.Major -ge 5) {
    Write-Host "[PASS] PowerShell Version: $psVer (>= 5.1)" -ForegroundColor Green
    $passes++
  } else {
    Write-Host "[FAIL] PowerShell Version: $psVer (< 5.1 required)" -ForegroundColor Red
    Write-Host "       Remediation: Upgrade to Windows PowerShell 5.1 or PowerShell 7." -ForegroundColor Yellow
    $fails++
  }

  # 2. Claude Desktop installation
  $claudeExe = Join-Path $env:LOCALAPPDATA 'Programs\Claude\Claude.exe'
  $aliasExe  = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\claude-desktop-msstore.exe'
  $hasPkg    = $false
  try {
    if (Get-Command Get-ClaudePackage -ErrorAction SilentlyContinue) {
      $pkg = Get-ClaudePackage
      if ($pkg) { $hasPkg = $true }
    }
  } catch { }

  if (Test-Path $claudeExe) {
    $verInfo = (Get-Item $claudeExe).VersionInfo.ProductVersion
    Write-Host "[PASS] Claude Desktop: Found at $claudeExe (version $verInfo)" -ForegroundColor Green
    $passes++
  } elseif (Test-Path $aliasExe) {
    Write-Host "[PASS] Claude Desktop: Found Microsoft Store execution alias at $aliasExe" -ForegroundColor Green
    $passes++
  } elseif ($hasPkg) {
    Write-Host "[PASS] Claude Desktop: Found MSStore package AnthropicPBC.ClaudeDesktop" -ForegroundColor Green
    $passes++
  } else {
    Write-Host "[FAIL] Claude Desktop: Not found at $claudeExe" -ForegroundColor Red
    Write-Host "       Remediation: Install Claude Desktop from https://claude.ai/download" -ForegroundColor Yellow
    $fails++
  }

  # 3. cc-switch directory / config
  $ccSwitchDir = Join-Path $env:APPDATA 'cc-switch'
  if (Test-Path $ccSwitchDir) {
    Write-Host "[PASS] cc-switch: Found configuration directory at $ccSwitchDir" -ForegroundColor Green
    $passes++
  } else {
    Write-Host "[PASS] cc-switch: Not detected (optional, required only for cc-switch profile sync)" -ForegroundColor Gray
    $passes++
  }

  # 4. instances.json format and integrity
  $cfgPath = $script:ConfigPath
  $cfgObj  = $null
  if (Test-Path $cfgPath) {
    try {
      $raw = Get-Content $cfgPath -Raw -Encoding UTF8
      $cfgObj = $raw | ConvertFrom-Json
      if ($cfgObj.instances) {
        Write-Host "[PASS] Config: instances.json valid with $($cfgObj.instances.Count) instance(s)" -ForegroundColor Green
        $passes++
      } else {
        Write-Host "[FAIL] Config: instances.json missing 'instances' array" -ForegroundColor Red
        Write-Host "       Remediation: Check JSON format in $cfgPath" -ForegroundColor Yellow
        $fails++
      }
    } catch {
      Write-Host "[FAIL] Config: Corrupted instances.json: $_" -ForegroundColor Red
      Write-Host "       Remediation: Fix JSON syntax in $cfgPath" -ForegroundColor Yellow
      $fails++
    }
  } else {
    Write-Host "[WARN] Config: instances.json not found at $cfgPath" -ForegroundColor Yellow
    Write-Host "       Remediation: Run 'claude-multi init' or launch GUI to create default configuration." -ForegroundColor Yellow
    $warns++
  }

  # 5. Proxy syntax and embedded credentials check
  $badProxies = @()
  if ($cfgObj -and $cfgObj.instances) {
    foreach ($inst in $cfgObj.instances) {
      if ($inst.proxy -and ($inst.proxy -match '://[^/@\s]+@' -or $inst.proxy -match '^[^/@\s]+@')) {
        $badProxies += $inst.name
      }
    }
  }
  if ($badProxies.Count -gt 0) {
    Write-Host "[WARN] Proxy Syntax: Instances with embedded credentials: $($badProxies -join ', ')" -ForegroundColor Yellow
    Write-Host "       Remediation: Chromium --proxy-server does not accept embedded credentials. For authenticated upstream proxies, route through a local unauthenticated gateway (e.g. 127.0.0.1:port) like cc-switch, Clash, or v2ray." -ForegroundColor Yellow
    $warns++
  } else {
    Write-Host "[PASS] Proxy Syntax: No unsupported embedded credentials found" -ForegroundColor Green
    $passes++
  }

  Write-Host ""
  $sumColor = if ($fails -gt 0) { "Red" } elseif ($warns -gt 0) { "Yellow" } else { "Green" }
  Write-Host "Summary: $passes PASS, $warns WARN, $fails FAIL" -ForegroundColor $sumColor

  return [pscustomobject]@{
    Passes = $passes
    Warns  = $warns
    Fails  = $fails
  }
}


# ---------------------------------------------------------------- background agent
function Invoke-Agent {
  $created = $false
  $mutex = New-Object Threading.Mutex($true, 'Local\ClaudeMultiAgent', [ref]$created)
  if (-not $created) { return }
  try {
    $idleSince = $null; $tick = 0; $applied = @{}; $focusFix = @{}
    while ($true) {
      $cfg = Read-Config; $all = @($cfg.instances)
      $mains = @(Get-ClaudeMains)
      $fg = [ShellProp]::ForegroundPid()
      if ($focusFix.Count) { Invoke-FocusFix $focusFix $mains $all; Start-Sleep -Milliseconds 250; continue }      # fast loop while a restart settles
      foreach ($m in $mains) {
        $i = Find-InstanceOf $m $all; if (-not $i) { continue }
        $p = Get-Process -Id $m.ProcessId -ErrorAction SilentlyContinue
        if (-not $p -or $p.MainWindowHandle -eq 0) { continue }
        Set-InstanceIdentity $i $m $p
        if ($m.ProcessId -eq $fg) { $s = Read-State; if ($s.lastActive -ne $i.id) { Save-State ([pscustomobject]@{ lastActive = $i.id }) } }
      }
      foreach ($id in @($script:Relaunch.Keys)) {
        $rl = $script:Relaunch[$id]; $inst = $all | Where-Object id -eq $id | Select-Object -First 1
        if (-not $inst) { $script:Relaunch.Remove($id); continue }
        if (@(Get-Roots $inst)) { $script:Relaunch.Remove($id); continue }
        if (((Get-Date) - $rl.at).TotalSeconds -gt 25) {
          if ($rl.tries -ge 3) { Write-AgentLog "giving up relaunching '$id'"; $script:Relaunch.Remove($id) }
          else { $rl.tries++; $rl.at = Get-Date; Write-AgentLog "relaunch '$id' (try $($rl.tries))"; try { Invoke-Launch $inst -NoAgent -Minimized } catch { Write-AgentLog "relaunch failed: $_" } }
        }
      }
      if ($tick % 3 -eq 0) {
        Register-Protocol
        if ($cfg.settings.syncSessions -and $mains.Count -gt 0) {
          try { Backup-Sessions; Initialize-SessionStores; [void](Invoke-SessionSync); if ($cfg.settings.syncSettings) { Invoke-SettingsSync $cfg $mains }; Invoke-LiveRefresh $cfg $mains $fg $focusFix } catch { Add-Content (Join-Path $StateDir 'agent.log') ("{0} {1}" -f (Get-Date -Format s), $_) }
        }
      }
      if ($tick % 6 -eq 0 -and $mains.Count -gt 1) { try { Invoke-ConcurrencyGuard $cfg $mains } catch { Add-Content (Join-Path $StateDir 'agent.log') ('{0} guard {1}' -f (Get-Date -Format s), $_) } }
      if ($mains.Count -eq 0) { if (-not $idleSince) { $idleSince = Get-Date } elseif (((Get-Date) - $idleSince).TotalSeconds -gt 90) { break } } else { $idleSince = $null }
      $tick++; Start-Sleep -Seconds 2
    }
  } finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}
