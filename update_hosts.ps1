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
$cfgFile = Join-Path $ScriptDir 'config.json'
if (Test-Path $cfgFile) {
    try {
        $c = Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($c.HostsTargets -and @($c.HostsTargets).Count -gt 0) { $Targets = @($c.HostsTargets) }
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
        Write-Host "[提示] 修改 hosts 需要管理员权限，正在请求提权..." -ForegroundColor Yellow
        Start-Process PowerShell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
        exit
    }
}
Write-Log "update_hosts.ps1 启动（Diag=$Diag；身份: $(if($isSystem){'SYSTEM'}elseif($isAdmin){'Admin'}else{'普通用户(将尝试提权)'}))"

# ---------- 1. 获取优先 / 正在使用的 IPv4 ----------
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
        # 取该网卡的非链路本地(169.254) IPv4
        $addr = Get-NetIPAddress -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notmatch '^169\.254\.' } | Select-Object -First 1
        if (-not $addr) { continue }
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $a.InterfaceIndex -ErrorAction SilentlyContinue |
                 Sort-Object RouteMetric | Select-Object -First 1
        $hasGw = [bool]$route
        $pool += [PSCustomObject]@{
            IP     = $addr.IPAddress
            IsWire = ($a.InterfaceType -ne 'Wireless80211')
            HasGw  = $hasGw
            Metric = if ($route) { $route.RouteMetric } else { [int]::MaxValue }
        }
    }
    if ($pool.Count -eq 0) { return $null }
    # 排序优先级：① 有默认网关（能上网）优先；② 有线优先于无线；③ 路由度量小者优先
    $best = $pool | Sort-Object @{Expression='HasGw';Descending=$true}, @{Expression='IsWire';Descending=$true}, @{Expression='Metric';Descending=$false} | Select-Object -First 1
    return $best.IP
}

# 多次重试探测 IPv4：刚切换网络（尤其手机热点 / 新 Wi-Fi）时 DHCP 可能尚未完成，
# 首次探测可能拿不到地址；最多重试 6 次、每次间隔 3 秒，避免“网络已切换但 hosts 未更新”。
$newIP = $null
for ($attempt = 1; $attempt -le 6; $attempt++) {
    $newIP = Get-PreferredIPv4
    if ($newIP) { break }
    if ($attempt -lt 6) {
        if (-not $Diag) { Write-Host "  第 $attempt 次未探测到 IPv4，3 秒后重试..." -ForegroundColor Gray }
        Write-Log "第 $attempt 次未探测到 IPv4，3 秒后重试..."
        Start-Sleep -Seconds 3
    }
}
if (-not $newIP) {
    Write-Host "[错误] 未检测到可用的 IPv4 地址，无法更新 hosts。" -ForegroundColor Red
    Write-Log "未检测到可用 IPv4，终止（已重试 6 次）。"
    exit 1
}
Write-Host "检测到当前网络 IPv4（优先 / 正在使用）：$newIP" -ForegroundColor Cyan
Write-Log "检测到 IPv4：$newIP"

# ---------- 2. 诊断模式：只读展示 ----------
if ($Diag) {
    Write-Host "`n===== hosts 相关行（只读）=====" -ForegroundColor Cyan
    if (Test-Path $HostsPath) {
        foreach ($line in (Get-Content $HostsPath -Encoding UTF8)) {
            $trimmed = $line.Trim()
            $isC = $trimmed.StartsWith('#')
            $tokens = $trimmed -split '\s+'
            $hosts = $tokens | Where-Object { $_ -and $_ -ne '#' -and -not $_.StartsWith('#') } | Select-Object -Skip 1
            $hit = ($hosts | Where-Object { $Targets -contains $_ }).Count -gt 0
            if ($hit) {
                $mark = if ($isC) { '（注释，将保留）' } else { "（将更新 IP -> $newIP）" }
                Write-Host ("  " + $line + "  " + $mark) -ForegroundColor $(if ($isC) { 'Gray' } else { 'Yellow' })
            }
        }
    }
    Write-Host "================================" -ForegroundColor Cyan
    Write-Host "诊断完成，未做任何修改。" -ForegroundColor Green
    exit 0
}

# ---------- 3. 读 hosts、仅更新未注释的目标行 ----------
if (-not (Test-Path $HostsPath)) {
    Write-Host "[错误] 找不到 hosts 文件：$HostsPath" -ForegroundColor Red
    exit 1
}

$lines    = Get-Content $HostsPath -Encoding UTF8
if ($UseModule) {
    # 走可单元测试的纯变换模块（保持逻辑单一来源，便于 Pester 离线覆盖）
    $result   = Update-HostsLines -Lines $lines -Targets $Targets -NewIP $newIP
    $newLines = $result.Lines
    foreach ($c in $result.Changes) {
        if ($c.StartsWith('UPDATE:')) {
            $tail   = $c.Substring(7)                       # "旧IP -> 新IP (hosts)"
            $m      = [regex]::Match($tail, '^(.*?) -> (.*?) \((.*)\)$')
            $oldIp  = $m.Groups[1].Value
            $newIp2 = $m.Groups[2].Value
            $hosts  = $m.Groups[3].Value
            Write-Host "  更新：$oldIp -> $newIp2  ($hosts)" -ForegroundColor Green
            Write-Log "更新行：$oldIp -> $newIp2 ($hosts)"
        } else {
            $tail = $c.Substring(5)                         # "新IP host"
            Write-Host "  追加：$tail" -ForegroundColor Yellow
            Write-Log "追加行：$tail"
        }
    }
} else {
    # 模块缺失时的内置同款回退（确保单文件拷贝也能运行）
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
            Write-Host "  更新：$ipTok -> $newIP  ($($matched -join ', '))" -ForegroundColor Green
            Write-Log "更新行：$ipTok -> $newIP ($($matched -join ', '))"
        } else {
            $newLines += $line
        }
    }
    # 对完全未在激活行出现的目标主机名，追加激活行（确保 hosts 始终含指向当前 IP 的生效映射）
    foreach ($t in $Targets) {
        if (-not $seen[$t]) {
            $newLines += "$newIP $t"
            Write-Host "  追加：$newIP $t" -ForegroundColor Yellow
            Write-Log "追加行：$newIP $t"
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
    Write-Host "`nhosts 无需更新（当前已为 $newIP，内容无变化），跳过写入。" -ForegroundColor Gray
    Write-Log "hosts 无需更新（当前已为 $newIP，内容无变化，跳过写入）。"
    exit 0
}

# 写回（直接覆盖，UTF-8 无 BOM，避免给 hosts 添加 BOM 头导致部分工具解析异常；不生成任何备份文件）
[System.IO.File]::WriteAllLines($HostsPath, [string[]]$newLines, [System.Text.UTF8Encoding]::new($false))

Write-Host "`nhosts 更新完成（已直接覆盖写入，无备份）。" -ForegroundColor Green
Write-Log "hosts 更新完成（直接覆盖写入，指向 $newIP）。"
