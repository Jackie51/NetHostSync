# ============================================================
# 更新 hosts 中的本地服务地址（功能优化脚本）
# 功能：
#   1. 检测当前网络环境，获取「优先使用 / 正在使用」的 IPv4 地址；
#      （有线、无线、手机热点同时连接时，优先选用有线网络的 IPv4）
#   2. 将 hosts 文件中未注释的目标配置项更新为该地址；
#      目标主机名列表由同目录 config.json 的 HostsTargets 指定（缺省回退
#      know.com / host.docker.internal / gateway.docker.internal 三项）。
#   3. 仅修改未被注释（激活）的行；保留其他配置与注释内容不变；
#      若某目标主机名在 hosts 中完全不存在，则追加一行激活配置（不影响已有内容）。
#   4. 直接覆盖写入 hosts，不生成任何备份文件（避免备份堆积占用空间）；
#      内容无变化时跳过写入（幂等，避免冗余写盘）。
#
# 用法：
#   右键「以管理员身份运行」本脚本（修改 hosts 必须管理员权限）。
#   诊断（只读，不需管理员）：powershell -File update_hosts.ps1 -Diag
# ============================================================

param(
    [switch]$Diag,          # 只读诊断：显示将使用的 IPv4 与 hosts 中相关行，不修改文件
    [string[]]$HostEntries  # 可选：临时覆盖目标主机名列表（不写 config.json）
)

$ScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir  = Split-Path -Parent $ScriptPath
$LogFile    = Join-Path $ScriptDir 'update_hosts.log'
$HostsPath  = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
# 复用可单元测试的纯变换模块（NetHostSync.psm1 与本脚本同目录）；
# 找不到时回退到内置同款逻辑，保证单文件也能运行。
$modPath = Join-Path $ScriptDir 'NetHostSync.psm1'
$UseModule = $false
if (Test-Path $modPath) {
    try { Import-Module $modPath -Force -ErrorAction Stop; $UseModule = $true } catch { }
}
# 目标主机名列表：优先读同目录 config.json 的 HostsTargets；缺省回退三项默认值；
# 命令行 -HostEntries 可临时覆盖（便于测试/特殊场景，不写 config.json）。
$defaultTargets = @('know.com', 'host.docker.internal', 'gateway.docker.internal')
$Targets = $defaultTargets
# IPv4 探测重试参数（可在 config.json 覆盖；默认 6 次、每次间隔 3 秒，与改造前一致）。
# 个别机器 DHCP 慢 / 重连竞态严重时，可只在该机 config.json 里调大（如 12 次 / 5 秒），不影响其他机器。
$IpRetryAttempts = 6
$IpRetrySeconds  = 3
$IpSettleSeconds = 0   # 探测前先短暂等待（秒），让拔线/插线瞬间的适配器状态竞态窗口稳定；默认 0 不等待。
$cfgFile = Join-Path $ScriptDir 'config.json'
if (Test-Path $cfgFile) {
    try {
        $c = Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($c.HostsTargets -and @($c.HostsTargets).Count -gt 0) { $Targets = @($c.HostsTargets) }
        if ($c.IpRetryAttempts)           { $IpRetryAttempts = $c.IpRetryAttempts }
        if ($c.IpRetrySeconds)            { $IpRetrySeconds = $c.IpRetrySeconds }
        if ($null -ne $c.IpSettleSeconds) { $IpSettleSeconds = $c.IpSettleSeconds }
    } catch { }
}
if ($HostEntries -and $HostEntries.Count -gt 0) { $Targets = $HostEntries }

# VPN / 虚拟网卡名称排除（与 network_config.ps1 一致），避免把 hosts 指向 VPN 隧道 IP
$VpnPattern = 'VPN|TAP|OpenVPN|WireGuard|Wintun|Cisco|AnyConnect|GlobalProtect|Forti|ZScaler|ZeroTrust|隧道|Tunnel|虚拟|WAN\s*Miniport|SoftEther|Check\s*Point|SonicWall|SSL\s*VPN'

function Write-Log($msg) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$ts  $msg" | Add-Content $LogFile -Encoding UTF8
}

# ---------- 管理员自检与提权 ----------
# 关键：计划任务以 SYSTEM（/RU SYSTEM）运行时，IsInRole(Administrator) 常返回 $false，
#       但 SYSTEM 实际拥有最高权限且无法走 UAC 交互提权（-Verb RunAs 会静默失败）。
#       因此：SYSTEM 或已是管理员 -> 直接执行；仅“非管理员且非 SYSTEM 的交互会话”才尝试 UAC。
$currentId = [Security.Principal.WindowsIdentity]::GetCurrent()
$isSystem  = ($currentId.User.Value -eq 'S-1-5-18') -or ($currentId.Name -eq 'NT AUTHORITY\SYSTEM')
$isAdmin   = ([Security.Principal.WindowsPrincipal]$currentId).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $isSystem) {
    if ($Diag) {
        # 诊断只读，无需提权
    } else {
        Write-Host "[TIP] modifying hosts requires administrator rights, requesting elevation..." -ForegroundColor Yellow
        Start-Process PowerShell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
        exit
    }
}
Write-Log "update_hosts.ps1 started(Diag=$Diag; identity: $(if($isSystem){'SYSTEM'}elseif($isAdmin){'Admin'}else{'standard user (will attempt elevation)'}))"

# ---------- 1. 获取优先 / 正在使用的 IPv4 ----------
# 区域无关判定某适配器是否为无线（与 network_config.ps1 的 Test-Wireless 保持一致的多重信号）：
# 1) InterfaceType 为 Wireless80211 或数值 71；2) 名称命中 WLAN / WI-?FI / WIRELESS / 无线（不分大小写）。
# 用于修正部分机器（如某些中文 Windows）把无线网卡 InterfaceType 误报为 Ethernet，
# 导致被当成「有线」参与优先排序、最终选错 IPv4 的问题。
function Test-WirelessAdapter($adapter) {
    if ($adapter.InterfaceType -eq 'Wireless80211' -or $adapter.InterfaceType -eq 71) { return $true }
    $name = "$($adapter.InterfaceAlias) $($adapter.Name)"
    if ($name -match 'WLAN|WI-?FI|WIRELESS|无线') { return $true }
    return $false
}
function Get-PreferredIPv4 {
    # 直接基于「当前已连接」的适配器探测，避免 Get-NetIPConfiguration 聚合到的残留/已断开网卡的旧网关。
    # 仅纳入：物理网卡 + 已连接(Up & Connected) + 非 Tunnel/环回 + 名称不命中 VPN 排除。
    $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
        $_.Status -eq 'Up' -and $_.MediaConnectionState -eq 'Connected' -and
        $_.InterfaceType -ne 'Tunnel' -and $_.InterfaceType -ne 'Loopback' -and
        $_.InterfaceAlias -notmatch $VpnPattern
    })
    $pool = @()
    foreach ($a in $adapters) {
        # 取该网卡的非链路本地(169.254) IPv4；并要求 AddressState=Preferred（已完全连接、生效中的地址）。
        # 关键：网卡拔线后，Windows 不会立即清除静态 IP，但会把该地址状态置为 Disconnected；
        # 仅凭适配器 MediaConnectionState 在“拔线瞬间事件刚触发”的竞态窗口里可能仍显示 Connected，
        # 故叠加 AddressState=Preferred 过滤，确保不会把已失效的有线静态 IP 当成“正在使用”写入 hosts。
        $addr = Get-NetIPAddress -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notmatch '^169\.254\.' -and $_.AddressState -eq 'Preferred' } | Select-Object -First 1
        if (-not $addr) { continue }
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $a.InterfaceIndex -ErrorAction SilentlyContinue |
                 Sort-Object RouteMetric | Select-Object -First 1
        $hasGw = [bool]$route
        $pool += [PSCustomObject]@{
            IP     = $addr.IPAddress
            IsWire = -not (Test-WirelessAdapter $a)
            HasGw  = $hasGw
            Metric = if ($route) { $route.RouteMetric } else { [int]::MaxValue }
        }
    }
    if ($pool.Count -eq 0) { return $null }
    # 排序优先级：① 有线优先于无线（脚本既定目标：有线/无线同连时优先选用有线 IPv4）；
    #             ② 同类型内，有默认网关（能上网）优先；③ 路由度量小者优先
    $best = $pool | Sort-Object @{Expression='IsWire';Descending=$true}, @{Expression='HasGw';Descending=$true}, @{Expression='Metric';Descending=$false} | Select-Object -First 1
    return $best.IP
}

# 多次重试探测 IPv4：刚切换网络（尤其手机热点 / 新 Wi-Fi）时 DHCP 可能尚未完成，
# 首次探测可能拿不到地址。重试次数 / 间隔 / 探测前等待均由 config.json 控制
# （IpRetryAttempts / IpRetrySeconds / IpSettleSeconds，默认 6 次、间隔 3 秒、不预等待），
# 与改造前行为一致；个别机器 DHCP 慢 / 重连竞态严重时才在该机 config.json 调大，不影响其他机器。
# 探测前先按配置短暂等待，让拔线/插线瞬间的适配器状态竞态窗口稳定（默认 0 秒，即不等待）。
if ($IpSettleSeconds -gt 0) { Start-Sleep -Seconds $IpSettleSeconds }
$newIP = $null
for ($attempt = 1; $attempt -le $IpRetryAttempts; $attempt++) {
    $newIP = Get-PreferredIPv4
    if ($newIP) { break }
    if ($attempt -lt $IpRetryAttempts) {
        if (-not $Diag) { Write-Host "  attempt ${attempt}: no IPv4 detected, retrying in ${IpRetrySeconds}s..." -ForegroundColor Gray }
        Write-Log "attempt ${attempt}: no IPv4 detected, retrying in ${IpRetrySeconds}s..."
        Start-Sleep -Seconds $IpRetrySeconds
    }
}
if (-not $newIP) {
    Write-Host "[ERROR] no usable IPv4 address detected, cannot update hosts." -ForegroundColor Red
    Write-Log "no usable IPv4 detected, aborting (retried $IpRetryAttempts times)."
    exit 1
}
Write-Host "current network IPv4 (preferred / in use) detected:$newIP" -ForegroundColor Cyan
Write-Log "IPv4 detected:$newIP"

# ---------- 2. 诊断模式：只读展示 ----------
if ($Diag) {
    Write-Host "`n===== hosts related lines (read-only)=====" -ForegroundColor Cyan
    if (Test-Path $HostsPath) {
        foreach ($line in (Get-Content $HostsPath -Encoding UTF8)) {
            $trimmed = $line.Trim()
            $isC = $trimmed.StartsWith('#')
            $tokens = $trimmed -split '\s+'
            $hosts = $tokens | Where-Object { $_ -and $_ -ne '#' -and -not $_.StartsWith('#') } | Select-Object -Skip 1
            $hit = ($hosts | Where-Object { $Targets -contains $_ }).Count -gt 0
            if ($hit) {
                $mark = if ($isC) { '(commented, kept)' } else { "(will update IP -> $newIP)" }
                Write-Host ("  " + $line + "  " + $mark) -ForegroundColor $(if ($isC) { 'Gray' } else { 'Yellow' })
            }
        }
    }
    Write-Host "================================" -ForegroundColor Cyan
    Write-Host "diagnostics done, no changes made." -ForegroundColor Green
    exit 0
}

# ---------- 3. 读 hosts、仅更新未注释的目标行 ----------
if (-not (Test-Path $HostsPath)) {
    Write-Host "[ERROR] hosts file not found:$HostsPath" -ForegroundColor Red
    exit 1
}

$lines    = Get-Content $HostsPath -Encoding UTF8
$newLines = $null
if ($UseModule) {
    # 走可单元测试的纯变换模块（保持逻辑单一来源，便于 Pester 离线覆盖）。
    # 关键：模块调用用 try/catch 包住——若模块版本不兼容、或个别 hosts 行触发其 bug 而抛异常，
    #       不中断脚本，直接降级回退到下方内置逻辑；保证「有模块 / 无模块 / 模块出错」三种情况下
    #       hosts 都能更新，彻底消除 update_hosts.ps1 与 NetHostSync.psm1 的执行冲突。
    try {
        $result   = Update-HostsLines -Lines $lines -Targets $Targets -NewIP $newIP
        $newLines = $result.Lines
        foreach ($c in $result.Changes) {
            if ($c.StartsWith('UPDATE:')) {
                $tail   = $c.Substring(7)                       # "旧IP -> 新IP (hosts)"
                $m      = [regex]::Match($tail, '^(.*?) -> (.*?) \((.*)\)$')
                $oldIp  = $m.Groups[1].Value
                $newIp2 = $m.Groups[2].Value
                $hosts  = $m.Groups[3].Value
                Write-Host "  updated:$oldIp -> $newIp2  ($hosts)" -ForegroundColor Green
                Write-Log "updated line:$oldIp -> $newIp2 ($hosts)"
            } else {
                $tail = $c.Substring(5)                         # "新IP host"
                Write-Host "  appended:$tail" -ForegroundColor Yellow
                Write-Log "appended line:$tail"
            }
        }
    } catch {
        Write-Log "module Update-HostsLines failed ($_), falling back to built-in logic."
        $UseModule = $false
    }
}
if (-not $UseModule) {
    # 模块缺失或调用失败时的内置同款回退（确保单文件拷贝也能运行）
    $newLines = @()
    $seen     = @{}   # 目标主机名是否已在「激活行」中出现（注释行不算，缺失则追加激活行）
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) {
            # 空行 / 注释行：原样保留（注释中出现的目标主机名不算“已存在”，缺失时仍会追加激活行）
            $newLines += $line
            continue
        }
        # 激活行
        $tokens   = $trimmed -split '\s+'
        $ipTok    = $tokens[0]
        $hostToks = $tokens | Where-Object { $_ -and $_ -ne '#' -and -not $_.StartsWith('#') } | Select-Object -Skip 1
        $matched  = @($hostToks | Where-Object { $Targets -contains $_ })
        foreach ($t in $matched) { $seen[$t] = $true }
        if ($matched.Count -gt 0) {
            # 仅替换首个 token（IP），其余（含前置缩进、内联注释、后续空格）原样保留。
            # 保留行首到 IP 起始位置的前缀（缩进/制表符），避免吞掉前导缩进。
            $idx     = $line.IndexOf($ipTok)
            $prefix  = $line.Substring(0, $idx)
            $rest    = $line.Substring($idx + $ipTok.Length)
            $newLines += ($prefix + $newIP + $rest)
            Write-Host "  updated:$ipTok -> $newIP  ($($matched -join ', '))" -ForegroundColor Green
            Write-Log "updated line:$ipTok -> $newIP ($($matched -join ', '))"
        } else {
            $newLines += $line
        }
    }
    # 对完全未在激活行出现的目标主机名，追加激活行（确保 hosts 始终含指向当前 IP 的生效映射）
    foreach ($t in $Targets) {
        if (-not $seen[$t]) {
            $newLines += "$newIP $t"
            Write-Host "  appended:$newIP $t" -ForegroundColor Yellow
            Write-Log "appended line:$newIP $t"
        }
    }
}

# 幂等：若计算后的内容与当前 hosts 完全一致，说明无需任何改动，直接跳过写入（避免冗余写盘）
$changed = $false
if ($lines.Count -ne $newLines.Count) { $changed = $true }
else {
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -ne $newLines[$i]) { $changed = $true; break }
    }
}
if (-not $changed) {
    Write-Host "`nhosts needs no update (already $newIP, content unchanged), skipping write." -ForegroundColor Gray
    Write-Log "hosts needs no update (already $newIP, content unchanged), skipping write."
    exit 0
}

# 写回（直接覆盖，UTF-8 无 BOM，避免给 hosts 添加 BOM 头导致部分工具解析异常；不生成任何备份文件）
[System.IO.File]::WriteAllLines($HostsPath, [string[]]$newLines, [System.Text.UTF8Encoding]::new($false))

Write-Host "`nhosts update complete (overwritten directly, no backup)." -ForegroundColor Green
Write-Log "hosts update complete (overwritten directly, pointing to $newIP)."
