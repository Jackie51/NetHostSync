# ============================================================
# 网络配置脚本（精简版）
# 规则：
#   有线网络 → 默认静态 IP（可手动更改具体数值）
#   无线网络 → 动态获取 IP（DHCP）
# 功能：一键自动、有线静态手动更改、无线 DHCP、网络变化自动触发（含 hosts 同步刷新）、
#        切换前备份 + 一键恢复、连通性校验、只读诊断。
#
# 用 PowerShell 编写，原生支持中文，不受 cmd 代码页影响。
# 外部配置 config.json（改默认参数不用碰本脚本）。
#
# 用法：
#   双击「网络配置.bat」进入交互菜单。
#   计划任务模式：powershell -File network_config.ps1 -Auto
#   注册/卸载自动触发：-InstallAuto / -UninstallAuto
#   只读诊断：-Diag
# ============================================================

param(
    [switch]$Auto,         # 静默自动模式（供计划任务/网络变化触发，不显示菜单）
    [switch]$InstallAuto,  # 注册“网络变化自动触发”计划任务
    [switch]$UninstallAuto, # 卸载该计划任务
    [switch]$Diag          # 只读诊断：显示各适配器真实状态（不改任何配置）
)

$ScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir  = Split-Path -Parent $ScriptPath
$ConfigFile = Join-Path $ScriptDir 'config.json'
$BackupFile = Join-Path $ScriptDir 'backup.json'
$LogFile    = Join-Path $ScriptDir 'network_switch.log'
$ScriptVersion = '1.0'

# ---------- 0. 控制台编码：修复 netsh 等原生命令的中文输出乱码 ----------
# 在 UTF-8 控制台（如 Windows Terminal / 系统已开启 UTF-8 支持）下，netsh 输出的是
# UTF-8 字节；若 PowerShell 仍按 GBK(936) 解码，就会变成“璇ヨ……”之类的乱码。
# 这里统一把控制台切到 UTF-8(65001)，并让 PowerShell 以 UTF-8 解码，彻底消除乱码。
# 仅作用于当前控制台会话，不改系统设置、不写注册表。
try {
    $null = chcp 65001 2>$null
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

# ---------- 0. 默认网络参数（config.json 存在时以其为准） ----------
# 有线网络默认静态配置
$DefaultIP      = '192.168.1.100'   # 有线静态 IP
$DefaultMask    = '255.255.255.0'    # 子网掩码
$DefaultGateway = '192.168.1.1'      # 默认网关
$DefaultDNS1    = '114.114.114.114'  # 首选 DNS
$DefaultDNS2    = '101.198.198.198'  # 备用 DNS（留空则不设）
$WiredMetric    = 10    # 有线优先级（越小越优先，配合无线 DHCP 实现有线优先）
$WirelessMetric = 20    # 无线优先级（备用，仅作参考）

# VPN / 虚拟网卡排除规则（正则）：名称命中或 Tunnel 类型一律不纳入 IP 管理，
# 避免误改 VPN 隧道网卡（如 OpenVPN TAP、WireGuard、Cisco AnyConnect 等虚拟以太网卡）。
# 可在 config.json 的 ExcludeAdapters 字段覆盖/扩展。
$ExcludePattern = 'VPN|TAP|OpenVPN|WireGuard|Wintun|Cisco|AnyConnect|GlobalProtect|Forti|ZScaler|ZeroTrust|隧道|Tunnel|虚拟|WAN\s*Miniport|SoftEther|Check\s*Point|SonicWall|SSL\s*VPN'

# 自动触发时是否同步刷新 hosts（调用 update_hosts.ps1，把本地服务地址指向当前 IPv4）；
# 设为 false 可关闭；UpdateHostsScript 为脚本文件名（位于 ScriptDir 下，一般无需改动）。
$UpdateHostsOnAuto = $true
$UpdateHostsScript = 'update_hosts.ps1'
# hosts 目标主机名列表（与 update_hosts.ps1 共享同一份 config.json 来源）；
# 此处仅作文档/缺省，真正读取在 update_hosts.ps1 内完成。
$HostsTargets = @('know.com', 'host.docker.internal', 'gateway.docker.internal')

# 读取外部配置文件（若存在则覆盖默认值）
if (Test-Path $ConfigFile) {
    try {
        $cfg = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.DefaultIP)      { $DefaultIP = $cfg.DefaultIP }
        if ($cfg.DefaultMask)    { $DefaultMask = $cfg.DefaultMask }
        if ($cfg.DefaultGateway) { $DefaultGateway = $cfg.DefaultGateway }
        if ($cfg.DefaultDNS1)    { $DefaultDNS1 = $cfg.DefaultDNS1 }
        if ($cfg.DefaultDNS2)    { $DefaultDNS2 = $cfg.DefaultDNS2 }
        if ($cfg.WiredMetric)    { $WiredMetric = $cfg.WiredMetric }
        if ($cfg.WirelessMetric) { $WirelessMetric = $cfg.WirelessMetric }
        if ($cfg.ExcludeAdapters) { $ExcludePattern = $cfg.ExcludeAdapters }
        if ($null -ne $cfg.UpdateHostsOnAuto) { $UpdateHostsOnAuto = [bool]$cfg.UpdateHostsOnAuto }
        if ($cfg.UpdateHostsScript) { $UpdateHostsScript = $cfg.UpdateHostsScript }
        if ($cfg.HostsTargets -and @($cfg.HostsTargets).Count -gt 0) { $HostsTargets = @($cfg.HostsTargets) }
    } catch {
        Write-Host "[警告] 读取配置文件失败，使用内置默认值：$_" -ForegroundColor Yellow
    }
} else {
    # 首次运行生成默认 config.json，便于以后修改
    $defaultCfg = [ordered]@{
        DefaultIP      = $DefaultIP
        DefaultMask    = $DefaultMask
        DefaultGateway = $DefaultGateway
        DefaultDNS1    = $DefaultDNS1
        DefaultDNS2    = $DefaultDNS2
        WiredMetric    = $WiredMetric
        WirelessMetric = $WirelessMetric
        ExcludeAdapters = $ExcludePattern
        UpdateHostsOnAuto = $UpdateHostsOnAuto
        UpdateHostsScript = $UpdateHostsScript
        HostsTargets = $HostsTargets
    }
    $defaultCfg | ConvertTo-Json | Set-Content $ConfigFile -Encoding UTF8
}

# ---------- 1. 管理员权限自检与自动提权 ----------
# 计划任务以 SYSTEM（/RU SYSTEM）运行时，IsInRole(Administrator) 可能返回 $false，
# 但 SYSTEM 拥有最高权限，应直接执行；同时 SYSTEM 无法走 UAC 交互提权（会静默失败）。
# 因此：SYSTEM 或已是管理员 -> 直接执行；仅“非管理员且非 SYSTEM”才尝试 UAC / 报错退出。
$currentId = [Security.Principal.WindowsIdentity]::GetCurrent()
$isSystem  = ($currentId.User.Value -eq 'S-1-5-18') -or ($currentId.Name -eq 'NT AUTHORITY\SYSTEM')
$isAdmin   = ([Security.Principal.WindowsPrincipal]$currentId).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $isSystem) {
    if ($Auto -or $InstallAuto -or $UninstallAuto) {
        # 自动/注册模式必须以管理员运行，非管理员直接退出，避免弹窗卡住后台任务
        Write-Host '[错误] 需要以管理员身份运行（请右键“以管理员身份运行”）。' -ForegroundColor Red
        exit 1
    }
    Write-Host "[提示] 当前未以管理员身份运行，正在请求提权..." -ForegroundColor Yellow
    Start-Process PowerShell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
    exit
}

# ============================================================
# 函数定义
# ============================================================

function Write-Log($msg) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$ts  $msg" | Add-Content $LogFile -Encoding UTF8
}

# 彻底清屏：同时清除可视区域与滚动缓冲区，避免 Windows Terminal / ConPTY 中
# `Clear-Host` 仅清可视区导致的残影、重影问题。
function Clear-Screen {
    # 用真实 ESC 字符（[char]27）构造 ANSI 序列，跨 PowerShell 5.1 / 7 都正确生效；
    # 注意 PowerShell 5.1 不识别 `e 转义，必须用 [char]27 才能得到真正的 ESC 字节。
    $useAnsi = $false
    try {
        $useAnsi = [bool]([System.Environment]::GetEnvironmentVariable('WT_SESSION')) -or
                   ([System.Environment]::GetEnvironmentVariable('TERM') -match 'xterm|vt') -or
                   ($PSVersionTable.PSVersion.Major -ge 6)
    } catch {}
    try {
        if ($useAnsi) {
            $esc = [char]27
            [Console]::Write("$esc[2J$esc[3J$esc[H")
        } else {
            Clear-Host
        }
    } catch {
        try { Clear-Host } catch {}
    }
}

# 用 netsh wlan 判定某适配器是否为无线（该命令只列出无线网卡，比 InterfaceType 可靠）
function Test-Wireless($adapter) {
    # 1) 接口类型（最可靠、区域无关）：Wireless80211 枚举（值 71）即无线
    if ($adapter.InterfaceType -eq 'Wireless80211' -or $adapter.InterfaceType -eq 71) { return $true }
    # 2) 名称启发（不区分大小写）：WLAN / Wi-Fi / Wireless / 无线 等
    if ($adapter.InterfaceAlias -match 'WLAN|WI-?FI|WIRELESS|无线') { return $true }
    if ($adapter.Name -match 'WLAN|WI-?FI|WIRELESS|无线') { return $true }
    # 3) netsh wlan show interfaces：该网卡已连 SSID 即无线。兼容中英文输出（名称/Name、:或：），名称模糊匹配。
    $wlan = netsh wlan show interfaces 2>$null
    $curIf = $null
    foreach ($line in $wlan) {
        if ($line -match '^\s*(Name|名称)\s*[:：]\s*(.+?)\s*$') { $curIf = $Matches[2].Trim() }
        if ($line -match '^\s*SSID\s*[:：]\s*(.+?)\s*$') {
            $a = $adapter.InterfaceAlias
            if ($curIf -and ($curIf -eq $a -or $curIf -like "*$a*" -or $a -like "*$curIf*")) { return $true }
        }
    }
    return $false
}

# 是否为应排除的适配器（VPN / 虚拟网卡）：Tunnel 类型 或 名称命中排除正则 → 不纳入 IP 管理
function Test-Excluded($adapter) {
    if ($adapter.InterfaceType -eq 'Tunnel') { return $true }
    if ($adapter.InterfaceAlias -match $ExcludePattern) { return $true }
    return $false
}

# 前缀长度 -> 点分掩码
function ConvertTo-DottedMask($prefixLen) {
    if (-not $prefixLen -or $prefixLen -lt 0 -or $prefixLen -gt 32) { return '255.255.255.0' }
    $mask = 0
    for ($i = 0; $i -lt $prefixLen; $i++) { $mask = ($mask -shl 1) -bor 1 }
    $mask = $mask -shl (32 - $prefixLen)
    $b1 = ($mask -shr 24) -band 255
    $b2 = ($mask -shr 16) -band 255
    $b3 = ($mask -shr 8)  -band 255
    $b4 = $mask -band 255
    return "$b1.$b2.$b3.$b4"
}

# 应用静态 IP（核心命令）
function Apply-Static($alias, $ip, $mask, $gw, $dns1, $dns2, $wireless) {
    $metric = if ($wireless) { $WirelessMetric } else { $WiredMetric }
    Write-Host "  IP=$ip  掩码=$mask  网关=$gw  DNS=$dns1$(if($dns2){' / '+$dns2}else{' (无备用)'})  优先级metric=$metric"
    # 用数字 InterfaceIndex 调 netsh，规避适配器名含前导/尾随空格导致 netsh 报“语法不正确”
    $idx = (Get-NetAdapter -InterfaceAlias $alias -ErrorAction SilentlyContinue | Select-Object -First 1).InterfaceIndex
    if (-not $idx) { Write-Host "[失败] 找不到适配器 [$alias]。" -ForegroundColor Red; return $false }
    Write-Host "`n正在将 [$alias] 设置为静态 IP..."
    if ($gw) {
        netsh interface ip set address name="$idx" static $ip $mask $gw
    } else {
        netsh interface ip set address name="$idx" static $ip $mask
    }
    if ($LASTEXITCODE -ne 0) { Write-Host "[失败] 设置静态 IP 失败，请检查输入。" -ForegroundColor Red; return $false }
    netsh interface ip delete dns name="$idx" all 2>$null
    netsh interface ip set dns name="$idx" static $dns1
    if ($dns2) { netsh interface ip add dns name="$idx" $dns2 index=2 }
    try {
        Set-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -InterfaceMetric $metric -ErrorAction Stop
        Write-Host "接口优先级已设置（metric=$metric）。" -ForegroundColor Green
    } catch {
        Write-Host "[提示] 设置接口优先级失败（不影响 IP/DNS）：$_" -ForegroundColor Yellow
    }
    Write-Host "静态 IP 设置完成。" -ForegroundColor Green
    return $true
}

# 分配前探活：检测目标 IPv4 是否已被本机其它网卡或局域网其它设备占用（避免 IP 冲突）
function Test-IpInUse($ip) {
    # 先发一个 ARP 探测（ping 填充邻居缓存），超时短
    ping.exe -n 1 -w 800 $ip > $null 2>&1
    try {
        $nb = Get-NetNeighbor -IPAddress $ip -ErrorAction SilentlyContinue
        if ($nb) {
            foreach ($n in $nb) {
                if ($n.LinkLayerAddress -and $n.State -ne 'Unreachable') { return $true }
            }
        }
    } catch {}
    # ICMP 探活兜底：部分设备禁 ARP 回显但响应 ping
    try { if (Test-Connection -ComputerName $ip -Count 1 -Quiet) { return $true } } catch {}
    return $false
}

# 带提示的静态配置（手动更改用）：回车用默认值，或输入新值修改
function Set-StaticWithPrompt($alias) {
    Write-Host "`n【静态 IP 配置】直接回车使用默认值，或输入新值修改（任一提示输入 q 取消并返回主菜单）：" -ForegroundColor Cyan
    $ip = Read-Host "IP 地址 [默认 $DefaultIP]（输入 q 取消）"; if ($ip -eq 'q') { Write-Host "已取消，返回主菜单。" -ForegroundColor Yellow; return $false }; if (-not $ip) { $ip = $DefaultIP }
    $mask = Read-Host "子网掩码 [默认 $DefaultMask，可留空]（输入 q 取消）"; if ($mask -eq 'q') { Write-Host "已取消，返回主菜单。" -ForegroundColor Yellow; return $false }; if (-not $mask) { $mask = $DefaultMask }
    $gw = Read-Host "默认网关 [默认 $DefaultGateway]（输入 q 取消）"; if ($gw -eq 'q') { Write-Host "已取消，返回主菜单。" -ForegroundColor Yellow; return $false }; if (-not $gw) { $gw = $DefaultGateway }
    $dns1 = Read-Host "首选 DNS [默认 $DefaultDNS1]（输入 q 取消）"; if ($dns1 -eq 'q') { Write-Host "已取消，返回主菜单。" -ForegroundColor Yellow; return $false }; if (-not $dns1) { $dns1 = $DefaultDNS1 }
    $dns2 = Read-Host "备用 DNS [默认 $DefaultDNS2，可留空]（输入 q 取消）"; if ($dns2 -eq 'q') { Write-Host "已取消，返回主菜单。" -ForegroundColor Yellow; return $false }; if (-not $dns2) { $dns2 = $DefaultDNS2 }
    # 分配前探活：避免把已在使用的 IP 设成本机静态地址导致冲突
    $cur = (Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
    if ($cur -and $cur -eq $ip) {
        Write-Host "[提示] 网卡 [$alias] 当前已是 $ip，将保持原配置。" -ForegroundColor Yellow
    } else {
        if (Test-IpInUse $ip) {
            Write-Host "[冲突] 检测到 $ip 已在局域网中使用（可能与其它设备或其它网卡撞 IP）。" -ForegroundColor Red
            Write-Host "        若仍要应用，可能造成 IP 冲突、网络异常。" -ForegroundColor Red
            $force = Read-Host "仍要强制应用此 IP? (y/N)"
            if ($force -notmatch '^[Yy]$') {
                Write-Host "已取消本次静态 IP 设置。" -ForegroundColor Yellow
                return $false
            }
            Write-Host "[警告] 用户选择强制应用，存在 IP 冲突风险。" -ForegroundColor Yellow
        }
    }
    return (Apply-Static $alias $ip $mask $gw $dns1 $dns2 $false)
}

function Set-Dhcp($alias) {
    $idx = (Get-NetAdapter -InterfaceAlias $alias -ErrorAction SilentlyContinue | Select-Object -First 1).InterfaceIndex
    if (-not $idx) { Write-Host "[失败] 找不到适配器 [$alias]。" -ForegroundColor Red; return $false }
    Write-Host "`n正在将 [$alias] 恢复为 DHCP 动态获取..."
    netsh interface ip set address name="$idx" dhcp
    netsh interface ip set dns name="$idx" dhcp
    # 显式设定无线优先级 metric=$WirelessMetric（默认 20），确保与有线(metric=10)同时连接时
    # 系统路由确定性优先走有线（满足「有线/无线/热点同时连接时优先选用有线」）。
    try {
        Set-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -InterfaceMetric $WirelessMetric -ErrorAction Stop
    } catch {}
    Write-Host "DHCP 设置完成。" -ForegroundColor Green
}

# 抓取适配器当前配置（用于切换前备份）
function Backup-Adapter($adapter) {
    $idx = $adapter.InterfaceIndex
    $addr = Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
    $gw = (Get-NetRoute -InterfaceIndex $idx -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop
    $dns = (Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
    $isDhcp = ($addr -and $addr.PrefixOrigin -eq 'Dhcp')
    return [ordered]@{
        Alias   = $adapter.InterfaceAlias
        Wireless = (Test-Wireless $adapter)
        Dhcp     = [bool]$isDhcp
        IP       = if ($addr) { $addr.IPAddress } else { '' }
        Mask     = if ($addr) { $addr.PrefixLength } else { '' }
        Gateway  = if ($gw) { $gw } else { '' }
        DNS1     = if ($dns -and $dns.Count -ge 1) { $dns[0] } else { '' }
        DNS2     = if ($dns -and $dns.Count -ge 2) { $dns[1] } else { '' }
    }
}

# 从备份恢复上一次配置
function Restore-Backup {
    if (-not (Test-Path $BackupFile)) { Write-Host "[提示] 没有找到备份文件（尚未做过切换）。" -ForegroundColor Yellow; return }
    try { $bk = Get-Content $BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Write-Host "[错误] 备份文件损坏：$_" -ForegroundColor Red; return }
    $list = if ($bk -is [Array]) { $bk } else { @($bk) }
    foreach ($e in $list) {
        $alias = $e.Alias
        Write-Host "`n恢复适配器 [$alias] 的上一次配置..."
        if ($e.Dhcp) {
            Set-Dhcp $alias
        } else {
            if (-not $e.IP -or -not $e.DNS1) { Write-Host "  备份中 [$alias] 的静态信息不完整，跳过。" -ForegroundColor Yellow; continue }
            $mask = ConvertTo-DottedMask $e.Mask
            Apply-Static $alias $e.IP $mask $e.Gateway $e.DNS1 $e.DNS2 $e.Wireless
        }
    }
    Show-Result $list[0].Alias
}

# 连通性校验：ping 网关与 DNS，区分本地链路异常与无外网
function Test-Connectivity($alias) {
    $cfg = Get-NetIPConfiguration -InterfaceAlias $alias -ErrorAction SilentlyContinue
    $gw = if ($cfg -and $cfg.IPv4DefaultGateway) { $cfg.IPv4DefaultGateway.NextHop } else { '' }
    if ($Auto) { Write-Log "连通性校验 [$alias] 网关=$gw" }
    if (-not $gw) { if (-not $Auto) { Write-Host "  [连通性] 未找到默认网关（DHCP 模式正常，无需静态网关）。" -ForegroundColor Gray }; return }

    # 刚改完 IP/网关，路由与 ARP 需 1~2 秒稳定，否则 ping 会“假不可达”
    Start-Sleep -Seconds 2

    # 多重判定，避免“路由器禁 ping”或“刚配置完”导致误报
    $arpOk = $false
    try {
        $arp = arp -a 2>$null
        foreach ($line in $arp) { if ($line -match [regex]::Escape($gw) -and $line -match '([0-9a-fA-F]{2}-){5}[0-9a-fA-F]{2}') { $arpOk = $true } }
    } catch {}

    $pingGw = Test-Connection -ComputerName $gw -Count 2 -Quiet -ErrorAction SilentlyContinue

    $tcpOk = $false
    try { $tcpOk = [bool](Test-NetConnection -ComputerName $DefaultDNS1 -Port 53 -InformationLevel Quiet -WarningAction SilentlyContinue) } catch {}

    if ($pingGw) { $l1 = "网关 $gw：可达 ✓" }
    elseif ($arpOk) { $l1 = "网关 $gw：未回应 ping，但 ARP 已解析（链路正常，路由器可能禁 ping）✓" }
    elseif ($tcpOk) { $l1 = "网关 $gw：未回应 ping，但外网 TCP 可达（链路正常）✓" }
    else { $l1 = "网关 $gw：不可达 ✗（本地链路可能异常）" }

    if ($tcpOk) { $l2 = "DNS $DefaultDNS1：可达 ✓" }
    elseif ($pingGw) { $l2 = "DNS $DefaultDNS1：ICMP 受限，但网关可达（链路正常）✓" }
    else { $l2 = "DNS $DefaultDNS1：不可达 ✗（可能无外网，但本地链路正常）" }

    if ($Auto) { Write-Log ("  " + $l1); Write-Log ("  " + $l2) } else {
        $c1 = if ($pingGw -or $arpOk -or $tcpOk) { 'Green' } else { 'Red' }
        Write-Host ("  [连通性] " + $l1) -ForegroundColor $c1
        Write-Host ("  [连通性] " + $l2) -ForegroundColor $(if($tcpOk){'Green'}else{'Yellow'})
    }
}

function Show-Result($alias) {
    $idx = (Get-NetAdapter -InterfaceAlias $alias -ErrorAction SilentlyContinue | Select-Object -First 1).InterfaceIndex
    Write-Host "`n============================================" -ForegroundColor Green
    Write-Host "当前网络配置状态（适配器：$alias）" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    if (-not $idx) {
        Write-Host "[提示] 未找到适配器 [$alias]，无法显示配置。" -ForegroundColor Yellow
    } else {
        # 用 PowerShell 原生对象读取，避免 netsh 中文输出乱码（区域/代码页无关）
        $addr = Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.InterfaceAlias -eq $alias } | Select-Object -First 1
        $gw   = (Get-NetRoute -InterfaceIndex $idx -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                Where-Object { $_.InterfaceAlias -eq $alias } | Select-Object -First 1).NextHop
        $dns  = (Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.InterfaceAlias -eq $alias }).ServerAddresses
        $ip   = if ($addr) { "$($addr.IPAddress)/$($addr.PrefixLength)" } else { '(无 IPv4)' }
        $type = if ($addr -and $addr.PrefixOrigin -eq 'Dhcp') { 'DHCP 动态获取' } else { '静态 IP' }
        $gwStr   = if ($gw) { $gw } else { '(无)' }
        $dnsStr  = if ($dns -and $dns.Count -gt 0) { $dns -join ' / ' } else { '(无)' }
        Write-Host ("  IP 地址    : " + $ip)
        Write-Host ("  获取方式   : " + $type)
        Write-Host ("  默认网关   : " + $gwStr)
        Write-Host ("  DNS 服务器 : " + $dnsStr)
    }
    ipconfig /flushdns 2>$null | Out-Null
    Write-Host "`n操作完成。" -ForegroundColor Green
    Write-Host "按任意键返回主菜单..." -NoNewline
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    Write-Host ""
}

# 网络变化时同步刷新 hosts（调用 update_hosts.ps1）：把 config.json 中 HostsTargets 指定的
# 目标主机名指向当前正在使用的 IPv4，仅改未注释行。由 UpdateHostsOnAuto 开关控制。
# 以独立 powershell 进程运行（继承 SYSTEM/管理员权限，无需再提权；其子进程 exit 不影响本脚本）。
# 等待网络就绪：切换网络（尤其手机热点 / 新 Wi-Fi）后 DHCP 可能尚未完成、IP 未分配，
# 此时若立即刷新 hosts 会写旧 IP / APIPA 或漏更新。轮询等待「任一已连接物理适配器拿到非链路本地 IPv4」，
# 最多等待 $TimeoutSec 秒（每 3 秒检查一次）；超时也返回（交给 update_hosts.ps1 自身重试兜底）。
function Wait-NetworkReady {
    param([int]$TimeoutSec = 60)
    $elapsed = 0
    $step    = 3
    while ($elapsed -lt $TimeoutSec) {
        $ready = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
            $_.Status -eq 'Up' -and $_.MediaConnectionState -eq 'Connected' -and -not (Test-Excluded $_)
        }) | ForEach-Object {
            $a = Get-NetIPAddress -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                 Where-Object { $_.IPAddress -notmatch '^169\.254\.' } | Select-Object -First 1
            [bool]$a
        } | Where-Object { $_ } | Select-Object -First 1
        if ($ready) { return $elapsed }
        Start-Sleep -Seconds $step
        $elapsed += $step
    }
    return $elapsed
}

function Invoke-HostsUpdate {
    if (-not $UpdateHostsOnAuto) { return }
    $updateScript = Join-Path $ScriptDir $UpdateHostsScript
    if (-not (Test-Path $updateScript)) {
        if (-not $Auto) { Write-Host "[提示] 未找到 $UpdateHostsScript，跳过 hosts 刷新。" -ForegroundColor Yellow }
        Write-Log "hosts 刷新：未找到脚本 $updateScript，跳过。"
        return
    }
    if ($Auto) { Write-Log "hosts 刷新：启动 $UpdateHostsScript（路径：$updateScript）..." }
    else { Write-Host "`n[hosts] 同步更新本地服务地址（调用 $UpdateHostsScript）..." -ForegroundColor Cyan }
    try {
        # 以独立 powershell 进程运行（继承 SYSTEM/管理员权限，无需再提权；输出由 2>&1 捕获后由父进程显示）。
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $updateScript 2>&1
        $code = $LASTEXITCODE
        if ($Auto) {
            foreach ($l in $output) { Write-Log ("hosts 刷新： " + $l.ToString()) }
            if ($code -eq 0) { Write-Log "hosts 刷新：完成（退出码 0）。" }
            else { Write-Log "hosts 刷新：脚本退出码 $code（可能未检测到可用 IPv4 或无改动）。" }
        } else {
            foreach ($l in $output) { Write-Host ("  " + $l.ToString()) -ForegroundColor $(if($code -eq 0){'Gray'}else{'Yellow'}) }
            if ($code -eq 0) { Write-Host "  [hosts] 刷新完成。" -ForegroundColor Green }
            else { Write-Host "  [hosts] 刷新未完成（退出码 $code），详见 update_hosts.log。" -ForegroundColor Yellow }
        }
    } catch {
        if ($Auto) { Write-Log "hosts 刷新：异常 - $($_.Exception.Message)" }
        else { Write-Host "  [hosts] 刷新异常：$($_.Exception.Message)" -ForegroundColor Red }
    }
}

# 自动模式核心（交互选项1 与 -Auto 共用）
# 规则：有线 → 默认静态；无线 → DHCP 动态获取。
# 关键：幂等、非侵入——对“已经处于目标状态”的适配器一律跳过，不重复下发指令，
#       避免打断 Windows 正在进行的 DHCP 握手（否则切换 Wi-Fi 后无线偶发断网）。
function Invoke-AutoConfig {
    try {
    $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.MediaConnectionState -eq 'Connected' -and -not (Test-Excluded $_) })
    if ($adapters.Count -eq 0) {
        $msg = "未检测到已连接的网络适配器。"
        if ($Auto) { Write-Log $msg } else { Write-Host "[错误] $msg" -ForegroundColor Red; Start-Sleep 2 }
        return
    }
    $changed = @()
    foreach ($adapter in $adapters) {
        $alias = $adapter.InterfaceAlias
        $idx   = $adapter.InterfaceIndex
        $isW   = Test-Wireless $adapter
        $medium = if ($isW) { '无线' } else { '有线' }
        $line = "检测到适配器：$alias（$medium）"
        if ($Auto) { Write-Log $line } else { Write-Host "`n$line" -ForegroundColor Cyan }
        $addr = Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($isW) {
            # 无线：仅当“当前不是 DHCP”（残留静态 IP）时才重置为 DHCP；
            #       已是 DHCP（切换 Wi-Fi 后系统会自动续租）→ 一律不动，避免打断握手导致断网。
            if ($addr -and $addr.PrefixOrigin -eq 'Dhcp') {
                if ($Auto) { Write-Log "-> 无线 $alias：已是 DHCP 动态获取，跳过（不干扰）。" }
                else { Write-Host "-> 无线 $alias：已是 DHCP，无需更改（跳过）" -ForegroundColor Gray }
                continue
            }
            if ($Auto) { Write-Log "-> 无线 $alias：检测到残留静态 IP，重置为 DHCP。" }
            else { Write-Host "-> 应用【无线 DHCP 动态获取】" -ForegroundColor Yellow }
            $changed += Backup-Adapter $adapter
            Set-Dhcp $alias
        } else {
            # 有线：当前是 DHCP → 套默认静态；当前是用户静态 → 保留跳过；
            #       当前是 APIPA(169.254.x.x 链路本地，未获有效地址) → 视为“无配置”，仍套默认静态。
            $isApi = ($addr -and $addr.IPAddress -match '^169\.254\.')
            if ($addr -and $addr.PrefixOrigin -ne 'Dhcp' -and -not $isApi) {
                if ($Auto) { Write-Log "-> 有线 $alias：已是静态（IP $($addr.IPAddress)），跳过。" }
                else { Write-Host "-> 有线 $alias：已是静态（IP $($addr.IPAddress)），无需更改（跳过）" -ForegroundColor Gray }
                continue
            }
            if ($isApi) {
                if ($Auto) { Write-Log "-> 有线 $alias：当前为 APIPA 链路本地地址($($addr.IPAddress)，未获有效地址)，应用默认静态（IP $DefaultIP）。" }
                else { Write-Host "-> 有线 $alias：当前为 APIPA 链路本地地址($($addr.IPAddress))，应用默认静态：$DefaultIP" -ForegroundColor Yellow }
            } else {
                if ($Auto) { Write-Log "-> 有线 $alias：当前为 DHCP，应用默认静态（IP $DefaultIP）。" }
                else { Write-Host "-> 应用【有线默认静态：$DefaultIP】" -ForegroundColor Yellow }
            }
            $changed += Backup-Adapter $adapter
            Apply-Static $alias $DefaultIP $DefaultMask $DefaultGateway $DefaultDNS1 $DefaultDNS2 $false
        }
    }
    # 连通性校验（针对主适配器：优先有线，否则第一个）
    $primary = @($adapters | Where-Object { -not (Test-Wireless $_) } | Select-Object -First 1)
    if ($primary.Count -eq 0) { $primary = @($adapters | Select-Object -First 1) }

    if ($changed.Count -gt 0) {
        $changed | ConvertTo-Json | Set-Content $BackupFile -Encoding UTF8
        Test-Connectivity $primary[0].InterfaceAlias
        if ($Auto) { Write-Log "自动切换完成（本次实际改动适配器数：$($changed.Count)）。" }
    } else {
        if ($Auto) { Write-Log "自动切换：所有适配器已处于目标状态，无需改动。" }
        else { Test-Connectivity $primary[0].InterfaceAlias }
    }
    # 网络配置更新后，同步刷新 hosts（指向当前 IPv4）；开关关闭则不执行
    return $primary[0].InterfaceAlias
    } finally {
        # 无论 IP 配置是否改动、是否检测到适配器，网络环境已变化，始终尝试同步 hosts
        Invoke-HostsUpdate
    }
}

# 交互模式下的适配器选择
function Get-ActiveAdapter {
    $list = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.MediaConnectionState -eq 'Connected' -and -not (Test-Excluded $_) })
    if ($list.Count -eq 0) { return $null }
    if ($list.Count -eq 1) { return $list[0] }
    Write-Host "`n检测到多个已连接的网络适配器，请选择要操作的那一张：" -ForegroundColor Cyan
    for ($i = 0; $i -lt $list.Count; $i++) {
        $a = $list[$i]
        $isWifi = Test-Wireless $a
        $medium = if ($isWifi) { '无线' } else { '有线' }
        $tagColor = if ($isWifi) { 'Magenta' } else { 'Yellow' }
        $ip = (Get-NetIPAddress -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
        Write-Host "  $($i+1). " -NoNewline
        Write-Host "[$medium] " -ForegroundColor $tagColor -NoNewline
        Write-Host $a.InterfaceAlias -NoNewline
        if ($ip) { Write-Host "  当前IP: $ip" } else { Write-Host '' }
    }
    $idx = 0
    do {
        $sel = Read-Host "请选择要操作的适配器序号（输入 q 取消返回主菜单）"
        if ($sel -eq 'q') { return '__CANCEL__' }
    } while (-not ([int]::TryParse($sel, [ref]$idx)) -or $idx -lt 1 -or $idx -gt $list.Count)
    return $list[$idx - 1]
}

# 注册/卸载“网络变化自动触发”计划任务
# 方案：把完整 schtasks /Create 命令写进一个临时 .cmd 批处理文件（cmd 原生 \" 转义），
#   再由本脚本“无参数启动”该 .cmd。这样所有引号转义都留在 .cmd 内部由 cmd 正确解析，
#   彻底绕开：① 早期「/TR 整串含引号被 PowerShell 破坏」；② TaskScheduler COM 的 Subscription 属性坑；
#   ③ 手搓 XML 的 Principal 顺序/LogonType 校验雷区（用户机器上报 ServiceAccount 越界）；
#   ④ ProcessStartInfo.Arguments 双层 CommandLineToArgvW 转义破坏内部 \" 的坑（报 'switch\… -Auto' 错参）。
#   /TR 内的 \" 在 .cmd 里是 cmd 原生合法转义，schtasks 自身生成合规 SYSTEM 主体。
function Install-AutoTask {
    # 权限守卫：注册 SYSTEM 计划任务 + 启用事件通道都需要管理员。
    # 菜单路径（菜单 4）下 $InstallAuto 为 $false，不会走脚本开头的提权检查，
    # 因此这里单独兜底——非管理员时自动以 RunAs 重启脚本并带 -InstallAuto 完成注册，
    # 避免“普通用户静默注册”导致 wevtutil/schtasks 失败、任务注册了却从不点火。
    if (-not ($isAdmin -or $isSystem)) {
        Write-Host '[提示] 注册计划任务需要管理员权限，正在请求提权...' -ForegroundColor Yellow
        Start-Process PowerShell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -InstallAuto"
        Write-Host '已在新窗口以管理员身份完成注册流程，完成后按任意键返回主菜单。' -ForegroundColor Gray
        return
    }
    $taskName = 'NetworkConfigAutoSwitch'
    $psExe    = (Get-Command powershell.exe).Source
    # 注册前先清理：卸载同名任务 + 任何指向本目录脚本的残留脏任务，
    # 防止早期异常注册尝试遗留多个名字不同但动作相同的任务不断累积。
    try {
        $t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($t) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop }
        @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
            $_.TaskName -ne $taskName -and $_.Actions -and (
                ($_.Actions.Execute -like '*network_config.ps1*') -or
                ($_.Actions.Execute -like '*update_hosts.ps1*') -or
                ($_.Actions.Arguments -like '*network_config.ps1*') -or
                ($_.Actions.Arguments -like '*update_hosts.ps1*') -or
                ($_.Actions.Execute -like '*One-click switch*') -or
                ($_.Actions.Arguments -like '*One-click switch*')
            )
        }) | ForEach-Object { Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction Stop }
    } catch {}
    # 启用事件通道：Microsoft-Windows-NetworkProfile/Operational 在某些系统默认未启用，
    # 若未启用则不会记录任何事件，事件触发器永远不会触发（自动任务形同虚设）。
    # 注册前显式启用（已启用则无害），确保网络变化事件能被计划任务捕获。
    try {
        & wevtutil.exe sl "Microsoft-Windows-NetworkProfile/Operational" /e:true 2>&1 | Out-Null
        Write-Log "启用自动触发：已确保事件通道 NetworkProfile/Operational 处于启用状态。"
    } catch {
        Write-Log "启用自动触发：启用事件通道失败（请手动在事件查看器中启用该通道）：$($_.Exception.Message)"
    }
    # .cmd 内的 schtasks 命令行：/TR 用 \" 包裹含空格的脚本路径（cmd 原生转义）
    # 触发事件：网络连接(10000) 与 网络断开(10001) 各用独立 EventTrigger（不用 or 复合条件，
    # 因 schtasks 事件触发器对 XPath `or` 支持不可靠，常只触发第一个条件），覆盖“插拔网线 / 切 Wi-Fi / 切热点”。
    # 用 XML 注册（比 cmd 拼 schtasks 更可靠：可精确控制 EventTrigger 订阅、SYSTEM 主体、电源条件）。
    # 触发组合（多重兜底，确保“网络变化后 hosts 一定能自修正”）：
    #   ① 事件触发：NetworkProfile/Operational 的 10000(连接)/10001(断开)，覆盖插拔网线 / 切 Wi-Fi / 切热点；
    #      这两个 EventID 各自独立 EventTrigger（不用 or 复合，schtasks 对 XPath or 支持不可靠）。
    #   ② 登录(AtLogOn)/启动(AtStartup)触发器：覆盖睡眠唤醒、重启后联网等事件偶发不点火的场景。
    #   ③ 【定时兜底 DailyTrigger】每 5 分钟跑一次：彻底消除“事件触发器漏抓（尤其有线断开 10001 不稳定）
    #      导致拔线后 hosts 永远不更新”的死角。脚本幂等，无变化时不写盘，开销极低。
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>SYSTEM</Author>
    <Description>网络变化时自动切换配置并刷新 hosts（NetHostSync）</Description>
  </RegistrationInfo>
  <Triggers>
    <!-- 顺序必须遵循 Task Scheduler XSD：BootTrigger → CalendarTrigger(DailyTrigger) → EventTrigger → LogonTrigger，
         否则注册报 "unexpected node"。 -->
    <BootTrigger><Enabled>true</Enabled></BootTrigger>
    <!-- 定时兜底：每天 00:00 起每 5 分钟跑一次（DailyTrigger+Repetition，永久循环），
         确保即使事件触发器漏抓（尤其有线断开 10001 不稳定），拔线/切网后 hosts 也至多 5 分钟内自修正。
         StopAtDurationEnd=false + Duration=P1D：每天重复 24h，次日 00:00 重新计时，形成永久每5分钟循环。 -->
    <DailyTrigger>
      <StartBoundary>2026-01-01T00:00:00</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
      <Repetition>
        <Interval>PT5M</Interval>
        <Duration>P1D</Duration>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
    </DailyTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"&gt;&lt;Select Path="Microsoft-Windows-NetworkProfile/Operational"&gt;*[System[(EventID=10000)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"&gt;&lt;Select Path="Microsoft-Windows-NetworkProfile/Operational"&gt;*[System[(EventID=10001)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
    <LogonTrigger><Enabled>true</Enabled></LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>SYSTEM</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT10M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$psExe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -File "$ScriptPath" -Auto</Arguments>
    </Exec>
  </Actions>
</Task>
"@
    $xmlFile = Join-Path $env:TEMP ('ncs_autotask.xml')
    try {
        # Task Scheduler 要求 XML 任务文件为 UTF-16 LE（带 BOM）。
        $sw = New-Object System.IO.StreamWriter($xmlFile, $false, [System.Text.UnicodeEncoding]::new($false, $true))
        $sw.Write($xml); $sw.Close()
        $output = & schtasks.exe /Create /TN "$taskName" /XML "$xmlFile" /F 2>&1
        $code = $LASTEXITCODE
        if ($code -eq 0) {
            Write-Host "[成功] 已注册计划任务「$taskName」。" -ForegroundColor Green
            Write-Host "  以后网络变化时（插拔网线/连不同 Wi-Fi）将自动切换配置并刷新 hosts（无需手动运行）。" -ForegroundColor Gray
            Write-Host "  规则：有线→默认静态，无线→DHCP；hosts 同步刷新到当前优先 IPv4。" -ForegroundColor Gray
            Write-Host "  触发方式：网络变化事件(即时) + 登录/启动 + 每5分钟定时兜底（拔线等事件偶发漏抓时至多5分钟内自修正）。" -ForegroundColor Gray
            Write-Host "  日志写入：$(Split-Path -Leaf $LogFile)" -ForegroundColor Gray
            Write-Host "  如需停用，选本菜单「停用自动触发」或运行 -UninstallAuto。" -ForegroundColor Gray
            Write-Host "  测试触发：管理员运行 'schtasks /Run /TN $taskName'，或 'network_config.ps1 -Auto'；" -ForegroundColor Gray
            Write-Host "            then 查 $LogFile 是否出现「自动模式启动」、任务「上次运行结果」是否变为 0。" -ForegroundColor Gray
            Write-Log "启用自动触发：成功注册计划任务 $taskName（EventTrigger + Logon/Boot 兜底）"
            # ---- 自检诊断：注册成功 ≠ 能点火 ----
            # 事件通道 NetworkProfile/Operational 若未真正启用，触发器永不点火；
            # 受限环境下 wevtutil 启用可能被静默拒绝，这里回读状态并明确告警。
            try {
                $chRaw = & wevtutil.exe gl "Microsoft-Windows-NetworkProfile/Operational" 2>&1 | Out-String
                if ($chRaw -match 'enabled:\s*true') {
                    Write-Host '  [自检] 事件通道 NetworkProfile/Operational 已启用 ✓（网络变化可触发）。' -ForegroundColor Green
                } else {
                    Write-Host '  [警告] 事件通道 NetworkProfile/Operational 未启用！自动触发将无法点火。' -ForegroundColor Red
                    Write-Host '    解决：事件查看器 → 应用程序和服务日志 → Microsoft → Windows → NetworkProfile → Operational → 右键“启用日志”。' -ForegroundColor Yellow
                    Write-Log '启用自动触发：自检发现事件通道未启用（自动触发不会点火）。'
                }
            } catch {
                Write-Log "启用自动触发：自检事件通道状态失败：$($_.Exception.Message)"
            }
            # 打印任务“上次运行结果 / 下次运行时间 / 触发器”，便于现场确认是否真的跑过
            try {
                & schtasks.exe /Query /TN $taskName /V /FO LIST 2>&1 | Where-Object {
                    $_ -match '上次运行|Last Result|下次运行|Next Run|触发器|Trigger'
                } | ForEach-Object { Write-Host "  [任务] $_" -ForegroundColor Gray }
            } catch {
                Write-Log "启用自动触发：读取任务诊断信息失败：$($_.Exception.Message)"
            }
        } else {
            Write-Host "[失败] 注册计划任务失败（退出码 $code）：" -ForegroundColor Red
            if ($output) { $output | ForEach-Object { Write-Host "  $($_.ToString().Trim())" -ForegroundColor Red } }
            Write-Log "启用自动触发：失败(退出码 $code) - $($output -join ' | ')"
        }
    } catch {
        Write-Host "[失败] 注册计划任务异常：$($_.Exception.Message)" -ForegroundColor Red
        Write-Log "启用自动触发：异常 - $($_.Exception.Message)"
    } finally {
        Remove-Item $xmlFile -Force -ErrorAction SilentlyContinue
    }
}

function Uninstall-AutoTask {
    $taskName = 'NetworkConfigAutoSwitch'
    $removed = @()
    # 方式一：按确切任务名卸载（优先用 PowerShell ScheduledTask cmdlet，错误信息更清晰）
    try {
        $t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($t) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
            $removed += $taskName
        }
    } catch {
        # cmdlet 不可用或失败时回退到 schtasks
        & schtasks.exe /Delete /TN $taskName /F 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $removed += $taskName }
    }
    # 方式二：扫描全部任务，清除任何「Action 指向本脚本 / hosts 脚本」的残留脏任务
    # （早期异常注册尝试可能留下了名字不同、但动作仍指向本目录脚本的任务）
    try {
        $strays = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
            $_.TaskName -ne $taskName -and $_.Actions -and (
                ($_.Actions.Execute -like '*network_config.ps1*') -or
                ($_.Actions.Execute -like '*update_hosts.ps1*') -or
                ($_.Actions.Execute -like '*One-click switch*')
            )
        })
        foreach ($s in $strays) {
            Unregister-ScheduledTask -TaskName $s.TaskName -Confirm:$false -ErrorAction Stop
            $removed += $s.TaskName
        }
    } catch {}
    if ($removed.Count -gt 0) {
        Write-Host "[成功] 已卸载自动触发任务：$($removed -join ', ')" -ForegroundColor Green
        Write-Log "停用自动触发：已卸载任务 $($removed -join ', ')"
    } else {
        Write-Host "[提示] 未发现已注册的自动触发任务（可能之前已卸载，无需处理）。" -ForegroundColor Gray
        Write-Log "停用自动触发：未发现已注册任务。"
    }
}

# ============================================================
# 只读诊断（不改任何配置）
# ============================================================
function Show-Diagnostics {
    Write-Host "`n===== 网络诊断（只读，不修改任何配置）=====" -ForegroundColor Cyan
    Write-Host "（请把下面内容原样发回，便于定位问题）" -ForegroundColor Gray
    $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.MediaConnectionState -eq 'Connected' -and -not (Test-Excluded $_) })
    if ($adapters.Count -eq 0) { Write-Host "[无] 未检测到已连接的物理适配器。" -ForegroundColor Yellow; return }
    foreach ($adapter in $adapters) {
        $idx = $adapter.InterfaceIndex; $alias = $adapter.InterfaceAlias
        $isW = Test-Wireless $adapter
        $ipCfg = Get-NetIPConfiguration -InterfaceIndex $idx -ErrorAction SilentlyContinue
        $addr = if ($ipCfg -and $ipCfg.IPv4Address) { $ipCfg.IPv4Address | Select-Object -First 1 } else { $null }
        $po = if ($addr) { $addr.PrefixOrigin } else { '(无地址)' }
        $gw = if ($ipCfg -and $ipCfg.IPv4DefaultGateway) { $ipCfg.IPv4DefaultGateway.NextHop } else { '(无)' }
        $dns = (Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
        $dnsStr = if ($dns) { $dns -join ' / ' } else { '(无)' }
        $willDo = if ($isW) { 'DHCP 动态获取' } else { "默认静态：$DefaultIP" }
        Write-Host "`n--- 适配器: $alias ---" -ForegroundColor Yellow
        Write-Host "  类型: $(if($isW){'无线'}else{'有线'})  状态: $($adapter.Status)  连接: $($adapter.MediaConnectionState)"
        Write-Host "  PrefixOrigin: $po  当前IP: $(if($addr){$addr.IPAddress}else{'(无)'})/$(if($addr){$addr.PrefixLength}else{'?'})"
        Write-Host "  默认网关: $gw"
        Write-Host "  DNS: $dnsStr"
        Write-Host "  [自动模式将执行] $willDo" -ForegroundColor Green
    }
    Write-Host "`n============================================" -ForegroundColor Cyan
}

# 返回主菜单前等待按键，避免结果被下一轮 Clear-Host 冲掉（“一闪而过”）
function Pause-Return {
    Write-Host "`n按任意键返回主菜单..." -NoNewline
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    Write-Host ""
}

# ============================================================
# 调度分发（非交互开关）
# ============================================================
if ($UninstallAuto) { Uninstall-AutoTask; exit }
if ($InstallAuto)   { Install-AutoTask;   exit }
if ($Diag)          { Show-Diagnostics; exit }
if ($Auto)          {
    Write-Log "自动模式启动（由网络变化事件触发）..."
    # 切换网络后先等待 IP 就绪（最多 60 秒），避免 hosts 刷到旧 IP / APIPA 或漏更新；
    # 即使超时也继续，由 update_hosts.ps1 自带的重试进一步兜底。
    $waited = Wait-NetworkReady -TimeoutSec 60
    Write-Log "自动模式：网络就绪等待完成（耗时 ${waited}s），开始刷新网络配置与 hosts。"
    Invoke-AutoConfig
    Write-Log "自动模式结束。"
    exit
}

# ============================================================
# 交互主循环
# ============================================================
while ($true) {
    Clear-Screen
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "    一键网络切换（静态 / 动态 / 自动）  v$ScriptVersion" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    $adminOK = ($isAdmin -or $isSystem)
    $adminText = if ($adminOK) { '管理员 ✓' } else { '非管理员 ✗（无权限修改网络配置，请右键“以管理员身份运行”）' }
    $adminColor = if ($adminOK) { 'Green' } else { 'Red' }
    Write-Host "  权限：" -NoNewline
    Write-Host $adminText -ForegroundColor $adminColor
    $connAdapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.MediaConnectionState -eq 'Connected' -and -not (Test-Excluded $_) })
    $wiredN = @($connAdapters | Where-Object { -not (Test-Wireless $_) }).Count
    $wirelessN = @($connAdapters | Where-Object { Test-Wireless $_ }).Count
    $autoOn = $false
    try { $at = Get-ScheduledTask -TaskName 'NetworkConfigAutoSwitch' -ErrorAction SilentlyContinue; if ($at -and $at.State -ne 'Disabled') { $autoOn = $true } } catch {}
    Write-Host "  连接：有线 $wiredN · 无线 $wirelessN ｜ 自动切换：$(if ($autoOn) { '已启用' } else { '未启用' })"
    Write-Host "规则：有线网络 → 默认静态 IP；无线网络 → 动态获取（DHCP）。"
    Write-Host "  1. 自动切换（有线→默认静态，无线→DHCP，并同步刷新 hosts）"
    Write-Host "  2. 设置静态 IP（手动更改默认值）"
    Write-Host "  3. 设置动态 IP（动态获取）"
    Write-Host "  4. 启用 网络变化自动触发（注册计划任务）"
    Write-Host "  5. 停用 网络变化自动触发"
    Write-Host "  6. 恢复上一次配置（从备份）"
    Write-Host "  7. 诊断（只读：显示各网卡真实状态，不改配置）"
    Write-Host "  8. 退出"
    Write-Host ""
    $choice = Read-Host "请输入选项 [1/2/3/4/5/6/7/8]"
    try {
    switch ($choice) {
        '1' {
            $pa = Invoke-AutoConfig
            if (-not $Auto -and $pa) { Show-Result $pa }
        }
        '2' {
            $adapter = Get-ActiveAdapter
            if ($adapter -eq '__CANCEL__') { Write-Host "已取消，返回主菜单。" -ForegroundColor Yellow; Start-Sleep 1; continue }
            if (-not $adapter) { Write-Host "[错误] 未检测到已连接的网络适配器。" -ForegroundColor Red; Start-Sleep 2; continue }
            $bk = Backup-Adapter $adapter
            $bk | ConvertTo-Json | Set-Content $BackupFile -Encoding UTF8
            if (Set-StaticWithPrompt $adapter.InterfaceAlias) {
                Test-Connectivity $adapter.InterfaceAlias
                Show-Result $adapter.InterfaceAlias
            } else { Pause-Return }
        }
        '3' {
            $adapter = Get-ActiveAdapter
            if ($adapter -eq '__CANCEL__') { Write-Host "已取消，返回主菜单。" -ForegroundColor Yellow; Start-Sleep 1; continue }
            if (-not $adapter) { Write-Host "[错误] 未检测到已连接的网络适配器。" -ForegroundColor Red; Start-Sleep 2; continue }
            $bk = Backup-Adapter $adapter
            $bk | ConvertTo-Json | Set-Content $BackupFile -Encoding UTF8
            Set-Dhcp $adapter.InterfaceAlias
            Test-Connectivity $adapter.InterfaceAlias
            Show-Result $adapter.InterfaceAlias
        }
        '4' { Install-AutoTask; Pause-Return }
        '5' { Uninstall-AutoTask; Pause-Return }
        '6' { Restore-Backup; Pause-Return }
        '7' { Show-Diagnostics; Write-Host "`n按任意键返回主菜单..." -NoNewline; $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown'); Write-Host "" }
        '8' { Write-Host "已退出。"; exit }
        default { Write-Host "[错误] 输入无效，请重新选择。" -ForegroundColor Red; Start-Sleep 2 }
        }
    } catch {
        # 单选项执行出错时显示错误并返回主菜单，避免脚本静默终止导致窗口闪退
        Write-Host "`n[异常] 执行该选项时出错，已返回主菜单：" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
        Start-Sleep 3
    }
}
