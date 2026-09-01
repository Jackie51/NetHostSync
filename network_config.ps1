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
#   双击「网络配置.bat」进入交互菜单（英文 ASCII，无残影）。
#   图形界面（中文、无残影）：双击「网络配置-GUI.bat」或 powershell -File network_config.ps1 -Gui
#   计划任务模式：powershell -File network_config.ps1 -Auto
#   注册/卸载自动触发：-InstallAuto / -UninstallAuto
#   只读诊断：-Diag
# ============================================================

param(
    [switch]$Auto,         # 静默自动模式（供计划任务/网络变化触发，不显示菜单）
    [switch]$InstallAuto,  # 注册“网络变化自动触发”计划任务
    [switch]$UninstallAuto, # 卸载该计划任务
    [switch]$Diag,         # 只读诊断：显示各适配器真实状态（不改任何配置）
    [switch]$Gui           # 图形界面模式：WinForms 中文界面（无控制台全角字形残影）
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
        Write-Host "[WARN] failed to read config file, using built-in defaults:$_" -ForegroundColor Yellow
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
        Write-Host '[ERROR] must run as Administrator (right-click and 'Run as Administrator').' -ForegroundColor Red
        exit 1
    }
    Write-Host "[TIP] not running as admin, requesting elevation..." -ForegroundColor Yellow
    $elevArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
    if ($Gui) { $elevArgs += ' -Gui' }
    Start-Process PowerShell.exe -Verb RunAs -ArgumentList $elevArgs
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
    Write-Host "  IP=$ip  mask=$mask  gateway=$gw  DNS=$dns1$(if($dns2){' / '+$dns2}else{' (no alternate)'})  metric=$metric"
    # 用数字 InterfaceIndex 调 netsh，规避适配器名含前导/尾随空格导致 netsh 报“语法不正确”
    $idx = (Get-NetAdapter -InterfaceAlias $alias -ErrorAction SilentlyContinue | Select-Object -First 1).InterfaceIndex
    if (-not $idx) { Write-Host "[FAIL] adapter not found [$alias]." -ForegroundColor Red; return $false }
    Write-Host "`nsetting [$alias] set to static IP..."
    if ($gw) {
        netsh interface ip set address name="$idx" static $ip $mask $gw
    } else {
        netsh interface ip set address name="$idx" static $ip $mask
    }
    if ($LASTEXITCODE -ne 0) { Write-Host "[FAIL] failed to set static IP, check input." -ForegroundColor Red; return $false }
    netsh interface ip delete dns name="$idx" all 2>$null
    netsh interface ip set dns name="$idx" static $dns1
    if ($dns2) { netsh interface ip add dns name="$idx" $dns2 index=2 }
    try {
        Set-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -InterfaceMetric $metric -ErrorAction Stop
        Write-Host "interface metric set(metric=$metric)." -ForegroundColor Green
    } catch {
        Write-Host "[TIP] failed to set interface metric (IP/DNS unaffected):$_" -ForegroundColor Yellow
    }
    Write-Host "static IP configuration complete." -ForegroundColor Green
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
    Write-Host "`n[Static IP Config]press Enter for defaults, or type a new value(enter q at any prompt to cancel and return to main menu):" -ForegroundColor Cyan
    $ip = Read-Host "IP address [default $DefaultIP](enter q to cancel)"; if ($ip -eq 'q') { Write-Host "cancelled, returning to main menu." -ForegroundColor Yellow; return $false }; if (-not $ip) { $ip = $DefaultIP }
    $mask = Read-Host "subnet mask [default $DefaultMask,may be empty](enter q to cancel)"; if ($mask -eq 'q') { Write-Host "cancelled, returning to main menu." -ForegroundColor Yellow; return $false }; if (-not $mask) { $mask = $DefaultMask }
    $gw = Read-Host "default gateway [default $DefaultGateway](enter q to cancel)"; if ($gw -eq 'q') { Write-Host "cancelled, returning to main menu." -ForegroundColor Yellow; return $false }; if (-not $gw) { $gw = $DefaultGateway }
    $dns1 = Read-Host "primary DNS [default $DefaultDNS1](enter q to cancel)"; if ($dns1 -eq 'q') { Write-Host "cancelled, returning to main menu." -ForegroundColor Yellow; return $false }; if (-not $dns1) { $dns1 = $DefaultDNS1 }
    $dns2 = Read-Host "secondary DNS [default $DefaultDNS2,may be empty](enter q to cancel)"; if ($dns2 -eq 'q') { Write-Host "cancelled, returning to main menu." -ForegroundColor Yellow; return $false }; if (-not $dns2) { $dns2 = $DefaultDNS2 }
    # 分配前探活：避免把已在使用的 IP 设成本机静态地址导致冲突
    $cur = (Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
    if ($cur -and $cur -eq $ip) {
        Write-Host "[TIP] adapter [$alias] already at $ip,keeping current config." -ForegroundColor Yellow
    } else {
        if (Test-IpInUse $ip) {
            Write-Host "[CONFLICT] detected $ip already in use on the LAN(possible IP conflict with another device or adapter)." -ForegroundColor Red
            Write-Host "        applying anyway may cause IP conflict or network issues." -ForegroundColor Red
            $force = Read-Host "force apply this IP anyway? (y/N)"
            if ($force -notmatch '^[Yy]$') {
                Write-Host "cancelled this static IP setup." -ForegroundColor Yellow
                return $false
            }
            Write-Host "[WARN] user chose to force apply; IP conflict risk exists." -ForegroundColor Yellow
        }
    }
    return (Apply-Static $alias $ip $mask $gw $dns1 $dns2 $false)
}

function Set-Dhcp($alias) {
    $idx = (Get-NetAdapter -InterfaceAlias $alias -ErrorAction SilentlyContinue | Select-Object -First 1).InterfaceIndex
    if (-not $idx) { Write-Host "[FAIL] adapter not found [$alias]." -ForegroundColor Red; return $false }
    Write-Host "`nsetting [$alias] restore to DHCP (dynamic)..."
    netsh interface ip set address name="$idx" dhcp
    netsh interface ip set dns name="$idx" dhcp
    # 显式设定无线优先级 metric=$WirelessMetric（默认 20），确保与有线(metric=10)同时连接时
    # 系统路由确定性优先走有线（满足「有线/无线/热点同时连接时优先选用有线」）。
    try {
        Set-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -InterfaceMetric $WirelessMetric -ErrorAction Stop
    } catch {}
    Write-Host "DHCP configuration complete." -ForegroundColor Green
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
    if (-not (Test-Path $BackupFile)) { Write-Host "[TIP] no backup file found (no switch performed yet)." -ForegroundColor Yellow; return }
    try { $bk = Get-Content $BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Write-Host "[ERROR] backup file corrupted:$_" -ForegroundColor Red; return }
    $list = if ($bk -is [Array]) { $bk } else { @($bk) }
    foreach ($e in $list) {
        $alias = $e.Alias
        Write-Host "`nrestore adapter [$alias] 's previous config..."
        if ($e.Dhcp) {
            Set-Dhcp $alias
        } else {
            if (-not $e.IP -or -not $e.DNS1) { Write-Host "  backup [$alias] has incomplete static info, skipping." -ForegroundColor Yellow; continue }
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
    if (-not $gw) { if (-not $Auto) { Write-Host "  [connectivity] no default gateway found (normal in DHCP mode, no static gateway needed)." -ForegroundColor Gray }; return }

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

    if ($pingGw) { $l1 = "gateway ${gw}:reachable [OK]" }
    elseif ($arpOk) { $l1 = "gateway ${gw}:not responding to ping, but ARP resolved (link OK, router may block ping)[OK]" }
    elseif ($tcpOk) { $l1 = "gateway ${gw}:not responding to ping, but external TCP reachable (link OK)[OK]" }
    else { $l1 = "gateway ${gw}:unreachable [X](local link may be abnormal)" }

    if ($tcpOk) { $l2 = "DNS ${DefaultDNS1}:reachable [OK]" }
    elseif ($pingGw) { $l2 = "DNS ${DefaultDNS1}:ICMP limited, but gateway reachable (link OK)[OK]" }
    else { $l2 = "DNS ${DefaultDNS1}:unreachable [X](possibly no internet, but local link OK)" }

    if ($Auto) { Write-Log ("  " + $l1); Write-Log ("  " + $l2) } else {
        $c1 = if ($pingGw -or $arpOk -or $tcpOk) { 'Green' } else { 'Red' }
        Write-Host ("  [connectivity] " + $l1) -ForegroundColor $c1
        Write-Host ("  [connectivity] " + $l2) -ForegroundColor $(if($tcpOk){'Green'}else{'Yellow'})
    }
}

function Show-Result($alias) {
    $idx = (Get-NetAdapter -InterfaceAlias $alias -ErrorAction SilentlyContinue | Select-Object -First 1).InterfaceIndex
    Write-Host "`n============================================" -ForegroundColor Green
    Write-Host "current network configuration (adapter: $alias)" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    if (-not $idx) {
        Write-Host "[TIP] adapter not found [$alias], cannot show config." -ForegroundColor Yellow
    } else {
        # 用 PowerShell 原生对象读取，避免 netsh 中文输出乱码（区域/代码页无关）
        $addr = Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.InterfaceAlias -eq $alias } | Select-Object -First 1
        $gw   = (Get-NetRoute -InterfaceIndex $idx -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                Where-Object { $_.InterfaceAlias -eq $alias } | Select-Object -First 1).NextHop
        $dns  = (Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.InterfaceAlias -eq $alias }).ServerAddresses
        $ip   = if ($addr) { "$($addr.IPAddress)/$($addr.PrefixLength)" } else { '(no IPv4)' }
        $type = if ($addr -and $addr.PrefixOrigin -eq 'Dhcp') { 'DHCP dynamic' } else { 'static IP' }
        $gwStr   = if ($gw) { $gw } else { '(none)' }
        $dnsStr  = if ($dns -and $dns.Count -gt 0) { $dns -join ' / ' } else { '(none)' }
        Write-Host ("  IP address    : " + $ip)
        Write-Host ("  obtain method   : " + $type)
        Write-Host ("  default gateway   : " + $gwStr)
        Write-Host ("  DNS Servers : " + $dnsStr)
    }
    ipconfig /flushdns 2>$null | Out-Null
    Write-Host "`noperation complete." -ForegroundColor Green
    Write-Host "press any key to return to main menu..." -NoNewline
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
        if (-not $Auto) { Write-Host "[TIP] not found $UpdateHostsScript, skipping hosts refresh." -ForegroundColor Yellow }
        Write-Log "hosts 刷新：未找到脚本 $updateScript，跳过。"
        return
    }
    if ($Auto) { Write-Log "hosts 刷新：启动 $UpdateHostsScript（路径：$updateScript）..." }
    else { Write-Host "`n[hosts] syncing local service addresses (calling $UpdateHostsScript)..." -ForegroundColor Cyan }
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
            if ($code -eq 0) { Write-Host "  [hosts] refresh complete." -ForegroundColor Green }
            else { Write-Host "  [hosts] refresh incomplete (exit code $code), see update_hosts.log." -ForegroundColor Yellow }
        }
    } catch {
        if ($Auto) { Write-Log "hosts 刷新：异常 - $($_.Exception.Message)" }
        else { Write-Host "  [hosts] refresh error:$($_.Exception.Message)" -ForegroundColor Red }
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
        $msg = "no connected network adapter detected."
        if ($Auto) { Write-Log $msg } else { Write-Host "[ERROR] $msg" -ForegroundColor Red; Start-Sleep 2 }
        return
    }
    $changed = @()
    foreach ($adapter in $adapters) {
        $alias = $adapter.InterfaceAlias
        $idx   = $adapter.InterfaceIndex
        $isW   = Test-Wireless $adapter
        $medium = if ($isW) { 'wireless' } else { 'wired' }
        $line = "detectedadapter:$alias($medium)"
        if ($Auto) { Write-Log $line } else { Write-Host "`n$line" -ForegroundColor Cyan }
        $addr = Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($isW) {
            # 无线：仅当“当前不是 DHCP”（残留静态 IP）时才重置为 DHCP；
            #       已是 DHCP（切换 Wi-Fi 后系统会自动续租）→ 一律不动，避免打断握手导致断网。
            if ($addr -and $addr.PrefixOrigin -eq 'Dhcp') {
                if ($Auto) { Write-Log "-> 无线 $alias：已是 DHCP 动态获取，跳过（不干扰）。" }
                else { Write-Host "-> wireless ${alias}:already DHCP, no change (skipped)" -ForegroundColor Gray }
                continue
            }
            if ($Auto) { Write-Log "-> 无线 $alias：检测到残留静态 IP，重置为 DHCP。" }
            else { Write-Host "-> applying[Wireless DHCP dynamic]" -ForegroundColor Yellow }
            $changed += Backup-Adapter $adapter
            Set-Dhcp $alias
        } else {
            # 有线：当前是 DHCP → 套默认静态；当前是用户静态 → 保留跳过；
            #       当前是 APIPA(169.254.x.x 链路本地，未获有效地址) → 视为“无配置”，仍套默认静态。
            $isApi = ($addr -and $addr.IPAddress -match '^169\.254\.')
            if ($addr -and $addr.PrefixOrigin -ne 'Dhcp' -and -not $isApi) {
                if ($Auto) { Write-Log "-> 有线 $alias：已是静态（IP $($addr.IPAddress)），跳过。" }
                else { Write-Host "-> wired ${alias}:already static (IP $($addr.IPAddress)), no change (skipped)" -ForegroundColor Gray }
                continue
            }
            if ($isApi) {
                if ($Auto) { Write-Log "-> 有线 $alias：当前为 APIPA 链路本地地址($($addr.IPAddress)，未获有效地址)，应用默认静态（IP $DefaultIP）。" }
                else { Write-Host "-> wired ${alias}:currently APIPA link-local ($($addr.IPAddress)), applying default static: $DefaultIP" -ForegroundColor Yellow }
            } else {
                if ($Auto) { Write-Log "-> 有线 $alias：当前为 DHCP，应用默认静态（IP $DefaultIP）。" }
                else { Write-Host "-> applying[Wired default static:$DefaultIP]" -ForegroundColor Yellow }
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
    Write-Host "`nmultiple connected adapters detected, please select one:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $list.Count; $i++) {
        $a = $list[$i]
        $isWifi = Test-Wireless $a
        $medium = if ($isWifi) { 'wireless' } else { 'wired' }
        $tagColor = if ($isWifi) { 'Magenta' } else { 'Yellow' }
        $ip = (Get-NetIPAddress -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
        Write-Host "  $($i+1). " -NoNewline
        Write-Host "[$medium] " -ForegroundColor $tagColor -NoNewline
        Write-Host $a.InterfaceAlias -NoNewline
        if ($ip) { Write-Host "  current IP: $ip" } else { Write-Host '' }
    }
    $idx = 0
    do {
        $sel = Read-Host "select adapter number (enter q to cancel and return to main menu)"
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
        Write-Host '[TIP] registering scheduled task requires admin, requesting elevation...' -ForegroundColor Yellow
        Start-Process PowerShell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -InstallAuto"
        Write-Host 'registration completed in new admin window, press any key to return to main menu.' -ForegroundColor Gray
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
    # 触发组合（多重兜底，确保“网络变化后 hosts 一定能自修正”）：
    #   ① 事件触发：NetworkProfile/Operational 的 10000(连接)/10001(断开)，覆盖插拔网线 / 切 Wi-Fi / 切热点；
    #      两个 EventID 各自独立 EventTrigger（不用 or 复合，schtasks 对 XPath or 支持不可靠）。
    #   ② 登录(AtLogOn)/启动(AtStartup)触发器：覆盖睡眠唤醒、重启后联网等事件偶发不点火的场景。
    #   ③ 【定时兜底】每 5 分钟跑一次（TimeTrigger + Repetition，Duration 10 年≈永久循环）：
    #       彻底消除“事件触发器漏抓（尤其有线断开 10001 不稳定）导致拔线后 hosts 永远不更新”的死角。
    #   改用 PowerShell Scheduled Task cmdlet（Register-ScheduledTask）构建任务对象，由系统生成合法 XML，
    #   绕开 schtasks.exe /Create /XML 对 Calendar/Daily 触发器及其 Repetition 解析不稳定的坑
    #   （曾反复报 “The task XML contains an unexpected node. ... DailyTrigger”）。
    try {
        $action = New-ScheduledTaskAction -Execute $psExe -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -Auto"
        # SYSTEM 服务账户主体，最高运行级别；比手搓 XML 的 Principal 更不易踩 LogonType 越界。
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        # 事件触发器：用 CIM 类 MSFT_TaskEventTrigger 直接构造 Subscription（避免 COM Subscription 属性坑）。
        $evtClass  = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
        $sub10000 = '<QueryList><Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"><Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[(EventID=10000)]]</Select></Query></QueryList>'
        $sub10001 = '<QueryList><Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"><Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[(EventID=10001)]]</Select></Query></QueryList>'
        $evt10000 = New-CimInstance -CimClass $evtClass -Property @{ Subscription = $sub10000; Enabled = $true } -ClientOnly
        $evt10001 = New-CimInstance -CimClass $evtClass -Property @{ Subscription = $sub10001; Enabled = $true } -ClientOnly
        # 登录 / 启动 触发器
        $logonTrig = New-ScheduledTaskTrigger -AtLogOn
        $bootTrig  = New-ScheduledTaskTrigger -AtStartup
        # 定时兜底：每 5 分钟一次，Duration 10 年（≈永久循环；-Once 起点在过去，Repetition 从当前持续向后）。
        $pollTrig  = New-ScheduledTaskTrigger -Once -At "2026-01-01T00:00:00" `
                        -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
        $triggers  = @($evt10000, $evt10001, $logonTrig, $bootTrig, $pollTrig)
        # 任务设置：电池也跑、不限期停、可随时按需运行、网络可用与否都跑、多实例忽略新实例。
        $settings  = New-ScheduledTaskSettingsSet `
                        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
                        -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew -Priority 7
        $result = Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal `
                    -Trigger $triggers -Settings $settings -Description "network change auto-switch config and refresh hosts(NetHostSync)" -Force
        if ($result) {
            Write-Host "[OK] scheduled task registered'$taskName'." -ForegroundColor Green
            Write-Host "  network changes (cable plug/unplug, different Wi-Fi) will auto-switch config and refresh hosts (no manual run)." -ForegroundColor Gray
            Write-Host "  rule: wired->default static, wireless->DHCP; hosts synced to preferred IPv4." -ForegroundColor Gray
            Write-Host "  triggers: network-change events (instant) + logon/startup + 5-min fallback (self-corrects within 5 min if an event is missed)." -ForegroundColor Gray
            Write-Host "  log written to:$(Split-Path -Leaf $LogFile)" -ForegroundColor Gray
            Write-Host "  to disable, choose 'Disable auto-trigger' in this menu or run -UninstallAuto." -ForegroundColor Gray
            Write-Host "  test trigger: run as admin 'schtasks /Run /TN $taskName', or 'network_config.ps1 -Auto';" -ForegroundColor Gray
            Write-Host "            then check $LogFile for'Auto mode started', task'Last Run Result'becomes 0." -ForegroundColor Gray
            Write-Log "启用自动触发：成功注册计划任务 $taskName（EventTrigger×2 + Logon/Boot + 每5分钟定时兜底）"
            # ---- 自检诊断：注册成功 ≠ 能点火 ----
            # 事件通道 NetworkProfile/Operational 若未真正启用，触发器永不点火；
            # 受限环境下 wevtutil 启用可能被静默拒绝，这里回读状态并明确告警。
            try {
                $chRaw = & wevtutil.exe gl "Microsoft-Windows-NetworkProfile/Operational" 2>&1 | Out-String
                if ($chRaw -match 'enabled:\s*true') {
                    Write-Host '  [SELF-CHECK] event channel NetworkProfile/Operational enabled [OK](network changecan trigger).' -ForegroundColor Green
                } else {
                    Write-Host '  [WARN] event channel NetworkProfile/Operational NOT enabled! auto-trigger will not fire.' -ForegroundColor Red
                    Write-Host '    fix:Event Viewer -> Applications and Services Logs -> Microsoft -> Windows -> NetworkProfile -> Operational -> right-click 'Enable Log'.' -ForegroundColor Yellow
                    Write-Log '启用自动触发：自检发现事件通道未启用（自动触发不会点火）。'
                }
            } catch {
                Write-Log "启用自动触发：自检事件通道状态失败：$($_.Exception.Message)"
            }
            # 打印任务“上次运行结果 / 下次运行时间 / 触发器”，便于现场确认是否真的跑过
            try {
                & schtasks.exe /Query /TN $taskName /V /FO LIST 2>&1 | Where-Object {
                    $_ -match '上次运行|Last Result|下次运行|Next Run|触发器|Trigger'
                } | ForEach-Object { Write-Host "  [TASK] $_" -ForegroundColor Gray }
            } catch {
                Write-Log "启用自动触发：读取任务诊断信息失败：$($_.Exception.Message)"
            }
        } else {
            Write-Host "[FAIL] scheduled task registration failed (Register-ScheduledTask returned no task object)." -ForegroundColor Red
            Write-Log "启用自动触发：失败(未返回任务对象)"
        }
    } catch {
        Write-Host "[FAIL] scheduled task registration error:$($_.Exception.Message)" -ForegroundColor Red
        Write-Log "启用自动触发：异常 - $($_.Exception.Message)"
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
        Write-Host "[OK] auto-trigger tasks uninstalled:$($removed -join ', ')" -ForegroundColor Green
        Write-Log "停用自动触发：已卸载任务 $($removed -join ', ')"
    } else {
        Write-Host "[TIP] no registered auto-trigger tasks found (already uninstalled, nothing to do)." -ForegroundColor Gray
        Write-Log "停用自动触发：未发现已注册任务。"
    }
}

# ============================================================
# 只读诊断（不改任何配置）
# ============================================================
function Show-Diagnostics {
    Write-Host "`n===== network diagnostics (read-only, no config changed)=====" -ForegroundColor Cyan
    Write-Host "(please send the output below as-is to help diagnose)" -ForegroundColor Gray
    $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.MediaConnectionState -eq 'Connected' -and -not (Test-Excluded $_) })
    if ($adapters.Count -eq 0) { Write-Host "[NONE] no connected physical adapter detected." -ForegroundColor Yellow; return }
    foreach ($adapter in $adapters) {
        $idx = $adapter.InterfaceIndex; $alias = $adapter.InterfaceAlias
        $isW = Test-Wireless $adapter
        $ipCfg = Get-NetIPConfiguration -InterfaceIndex $idx -ErrorAction SilentlyContinue
        $addr = if ($ipCfg -and $ipCfg.IPv4Address) { $ipCfg.IPv4Address | Select-Object -First 1 } else { $null }
        $po = if ($addr) { $addr.PrefixOrigin } else { '(noneaddress)' }
        $gw = if ($ipCfg -and $ipCfg.IPv4DefaultGateway) { $ipCfg.IPv4DefaultGateway.NextHop } else { '(none)' }
        $dns = (Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
        $dnsStr = if ($dns) { $dns -join ' / ' } else { '(none)' }
        $willDo = if ($isW) { 'DHCP dynamic' } else { "default static:$DefaultIP" }
        Write-Host "`n--- adapter: $alias ---" -ForegroundColor Yellow
        Write-Host "  type: $(if($isW){'wireless'}else{'wired'})  status: $($adapter.Status)  connection: $($adapter.MediaConnectionState)"
        Write-Host "  PrefixOrigin: $po  current IP: $(if($addr){$addr.IPAddress}else{'(none)'})/$(if($addr){$addr.PrefixLength}else{'?'})"
        Write-Host "  default gateway: $gw"
        Write-Host "  DNS: $dnsStr"
        Write-Host "  [auto mode will do] $willDo" -ForegroundColor Green
    }
    Write-Host "`n============================================" -ForegroundColor Cyan
}

# 返回主菜单前等待按键，避免结果被下一轮 Clear-Host 冲掉（“一闪而过”）
function Pause-Return {
    Write-Host "`npress any key to return to main menu..." -NoNewline
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    Write-Host ""
}

# ============================================================
# 图形界面模式（-Gui）：仪表盘式中文界面，顶部状态总览 + 核心“一键自动切换”大按钮 + 次级操作按钮。
# 字体用 Microsoft YaHei（中文 Windows 自带）。注：若仍见全角字右侧淡影，属系统 ClearType 抗锯齿
# （影响控制台/WT/WinForms 所有文本渲染），需在“显示设置”关闭“平滑屏幕字体边缘”或改用非 ClearType 字体。
# 所有动作复用下方已有的引擎函数；输出用 *>&1 重定向到日志框（捕获 Write-Host / 原生命令输出）。
# ============================================================
function Show-Gui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $script:busy = $false
    $script:adapters = @()
    $script:ipFields = @{}

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "NetHostSync 网络配置  v$ScriptVersion"
    $form.Size = New-Object System.Drawing.Size(560, 810)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Microsoft YaHei', 9)
    $form.BackColor = [System.Drawing.Color]::FromArgb(245,247,250)
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = 'NetHostSync  一键网络切换 + hosts 同步'
    $lblTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei', 12, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = New-Object System.Drawing.Point(20,12)
    $lblTitle.Size = New-Object System.Drawing.Size(500,24)
    $lblTitle.AutoSize = $false
    $form.Controls.Add($lblTitle)

    $adminOK = ($isAdmin -or $isSystem)
    $lblPriv = New-Object System.Windows.Forms.Label
    if ($adminOK) { $lblPriv.Text = '权限: 管理员 [OK]' ; $lblPriv.ForeColor = [System.Drawing.Color]::Green }
    else { $lblPriv.Text = '权限: 非管理员 [!] 部分功能受限'; $lblPriv.ForeColor = [System.Drawing.Color]::Red }
    $lblPriv.Location = New-Object System.Drawing.Point(20,40)
    $lblPriv.Size = New-Object System.Drawing.Size(500,18)
    $lblPriv.AutoSize = $false
    $form.Controls.Add($lblPriv)

    # ---- 状态总览面板（体现"整体"）----
    $grpStatus = New-Object System.Windows.Forms.GroupBox
    $grpStatus.Text = '当前状态'
    $grpStatus.Location = New-Object System.Drawing.Point(20,64)
    $grpStatus.Size = New-Object System.Drawing.Size(500,108)
    $form.Controls.Add($grpStatus)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Font = New-Object System.Drawing.Font('Microsoft YaHei', 9)
    $lblStatus.Location = New-Object System.Drawing.Point(12,18)
    $lblStatus.Size = New-Object System.Drawing.Size(400,84)
    $lblStatus.AutoSize = $false
    $grpStatus.Controls.Add($lblStatus)

    $btnStatus = New-Object System.Windows.Forms.Button
    $btnStatus.Text = '刷新状态'
    $btnStatus.Location = New-Object System.Drawing.Point(420,22)
    $btnStatus.Size = New-Object System.Drawing.Size(70,24)
    $grpStatus.Controls.Add($btnStatus)

    # ---- 核心集成动作：一键自动切换（刷网络配置 + hosts 同步）----
    $btnAuto = New-Object System.Windows.Forms.Button
    $btnAuto.Text = '① 一键自动切换（刷网络配置 + hosts 同步）'
    $btnAuto.Font = New-Object System.Drawing.Font('Microsoft YaHei', 11, [System.Drawing.FontStyle]::Bold)
    $btnAuto.Location = New-Object System.Drawing.Point(20,182)
    $btnAuto.Size = New-Object System.Drawing.Size(500,46)
    $btnAuto.BackColor = [System.Drawing.Color]::FromArgb(0,120,215)
    $btnAuto.ForeColor = [System.Drawing.Color]::White
    $form.Controls.Add($btnAuto)

    # ---- 次级操作按钮 ----
    $btnSpecs = @(
        @{ t='② 有线->静态IP'; c={ Run-Static } },
        @{ t='③ 无线->DHCP';   c={ Run-Dhcp } },
        @{ t='④ 启用自动触发'; c={ Run-Action -sb { Install-AutoTask } } },
        @{ t='⑤ 停用自动触发'; c={ Run-Action -sb { Uninstall-AutoTask } } },
        @{ t='⑥ 恢复上次配置'; c={ Run-Restore } },
        @{ t='⑦ 只读诊断';     c={ Run-Action -sb { Show-Diagnostics } } },
        @{ t='⑧ 退出';         c={ $form.Close() } }
    )
    $script:actionButtons = @()
    for ($i = 0; $i -lt $btnSpecs.Count; $i++) {
        $r = [math]::Floor($i / 2); $col = $i % 2
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $btnSpecs[$i].t
        $b.Font = New-Object System.Drawing.Font('Microsoft YaHei', 10)
        $b.Location = New-Object System.Drawing.Point(20 + $col * 260, 238 + $r * 40)
        $b.Size = New-Object System.Drawing.Size(240, 34)
        $b.Add_Click($btnSpecs[$i].c)
        $form.Controls.Add($b)
        $script:actionButtons += $b
    }

    # ---- 静态IP 输入区 ----
    $grpIp = New-Object System.Windows.Forms.GroupBox
    $grpIp.Text = '静态IP（可选，留空用默认；仅②用到）'
    $grpIp.Location = New-Object System.Drawing.Point(20,404)
    $grpIp.Size = New-Object System.Drawing.Size(500,126)
    $form.Controls.Add($grpIp)

    $fields = @(
        @{ l='IP';   v=$DefaultIP;      ref='txtIp';   row=0; col=0 },
        @{ l='掩码'; v=$DefaultMask;    ref='txtMask'; row=0; col=1 },
        @{ l='网关'; v=$DefaultGateway; ref='txtGw';   row=0; col=2 },
        @{ l='DNS1'; v=$DefaultDNS1;    ref='txtDns1'; row=1; col=0 },
        @{ l='DNS2'; v=$DefaultDNS2;    ref='txtDns2'; row=1; col=1 }
    )
    foreach ($f in $fields) {
        $x = 14 + $f.col * 160
        $yLabel = 22 + $f.row * 48
        $yBox   = 40 + $f.row * 48
        $lab = New-Object System.Windows.Forms.Label
        $lab.Text = $f.l
        $lab.Location = New-Object System.Drawing.Point($x, $yLabel)
        $lab.Size = New-Object System.Drawing.Size(140, 18)
        $lab.AutoSize = $false
        $grpIp.Controls.Add($lab)
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Text = $f.v
        $tb.Location = New-Object System.Drawing.Point($x, $yBox)
        $tb.Size = New-Object System.Drawing.Size(140, 22)
        $grpIp.Controls.Add($tb)
        $script:ipFields[$f.ref] = $tb
    }

    # ---- 目标网卡选择（②⑥⑦ 用到）----
    $lblAdp = New-Object System.Windows.Forms.Label
    $lblAdp.Text = '目标网卡:'
    $lblAdp.Location = New-Object System.Drawing.Point(20,542)
    $lblAdp.Size = New-Object System.Drawing.Size(70,18)
    $lblAdp.AutoSize = $false
    $form.Controls.Add($lblAdp)

    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.DropDownStyle = 'DropDownList'
    $combo.Location = New-Object System.Drawing.Point(95,540)
    $combo.Size = New-Object System.Drawing.Size(330,23)
    $form.Controls.Add($combo)

    $btnRefreshAdp = New-Object System.Windows.Forms.Button
    $btnRefreshAdp.Text = '刷新网卡'
    $btnRefreshAdp.Location = New-Object System.Drawing.Point(435,539)
    $btnRefreshAdp.Size = New-Object System.Drawing.Size(80,24)
    $form.Controls.Add($btnRefreshAdp)

    # ---- 日志区 ----
    $lblLog = New-Object System.Windows.Forms.Label
    $lblLog.Text = '运行日志'
    $lblLog.Location = New-Object System.Drawing.Point(20,572)
    $lblLog.Size = New-Object System.Drawing.Size(400,18)
    $lblLog.AutoSize = $false
    $form.Controls.Add($lblLog)

    $btnClear = New-Object System.Windows.Forms.Button
    $btnClear.Text = '清空日志'
    $btnClear.Location = New-Object System.Drawing.Point(420,570)
    $btnClear.Size = New-Object System.Drawing.Size(100,22)
    $form.Controls.Add($btnClear)

    $rtb = New-Object System.Windows.Forms.RichTextBox
    $rtb.Location = New-Object System.Drawing.Point(20,594)
    $rtb.Size = New-Object System.Drawing.Size(500,170)
    $rtb.ReadOnly = $true
    $rtb.Font = New-Object System.Drawing.Font('Consolas', 9)
    $rtb.BackColor = [System.Drawing.Color]::FromArgb(30,30,30)
    $rtb.ForeColor = [System.Drawing.Color]::LightGray
    $form.Controls.Add($rtb)

    function Add-Log($line) {
        $c = 'LightGray'
        if ($line -match '\[ERROR\]|\[FAIL\]|unreachable|异常') { $c = 'Red' }
        elseif ($line -match '\[OK\]|complete|enabled|成功|refreshed') { $c = 'LimeGreen' }
        elseif ($line -match '\[TIP\]|\[WARN\]|conflict|cancel|取消|跳过') { $c = 'Gold' }
        elseif ($line -match 'applying|setting|detected|restore|refresh') { $c = 'SkyBlue' }
        $rtb.SelectionStart = $rtb.Text.Length
        $rtb.SelectionColor = [System.Drawing.Color]::FromName($c)
        $rtb.AppendText($line + [Environment]::NewLine)
        [System.Windows.Forms.Application]::DoEvents()
    }

    function Set-ButtonsEnabled($on) {
        foreach ($b in $script:actionButtons) { $b.Enabled = $on }
        $btnAuto.Enabled = $on
    }

    function Get-SelAlias {
        if ($combo.SelectedIndex -lt 0 -or $script:adapters.Count -eq 0) { return $null }
        return $script:adapters[$combo.SelectedIndex].InterfaceAlias
    }

    function Refresh-Status {
        try {
            $conn = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.MediaConnectionState -eq 'Connected' -and -not (Test-Excluded $_) })
            $a = $conn | Select-Object -First 1
            $type = if ($a -and (Test-Wireless $a)) { '无线' } else { '有线' }
            $ip = if ($a) { (Get-NetIPAddress -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress } else { '(无)' }
            $autoOn = $false
            try { $at = Get-ScheduledTask -TaskName 'NetworkConfigAutoSwitch' -ErrorAction SilentlyContinue; if ($at -and $at.State -ne 'Disabled') { $autoOn = $true } } catch {}
            $hostsState = if ($autoOn) { '启用自动触发后随切换刷新' } else { '未启用自动触发（手动切换时也刷新）' }
            $lblStatus.Text = "当前网卡: $(if ($a) { $a.InterfaceAlias } else { '(未检测到已连接网卡)' })`n" +
                              "连接类型: $type`n" +
                              "当前 IPv4: $ip`n" +
                              "自动触发: $(if ($autoOn) { '已启用' } else { '未启用' })`n" +
                              "hosts 同步: $hostsState"
        } catch {
            $lblStatus.Text = "[ERROR] 读取状态失败: $($_.Exception.Message)"
        }
    }

    function Fill-Adapters {
        $combo.Items.Clear()
        $list = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.MediaConnectionState -eq 'Connected' -and -not (Test-Excluded $_) })
        $script:adapters = $list
        if ($list.Count -eq 0) { $combo.Items.Add('(未检测到已连接网卡)') | Out-Null; $combo.SelectedIndex = 0 }
        else {
            foreach ($a in $list) {
                $ip = (Get-NetIPAddress -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
                $tag = if (Test-Wireless $a) { '无线' } else { '有线' }
                $combo.Items.Add("[$tag] $($a.InterfaceAlias)  ($ip)") | Out-Null
            }
            $combo.SelectedIndex = 0
        }
    }

    function Run-Action {
        param([scriptblock]$sb, [object[]]$argsList = @())
        if ($script:busy) { return }
        $script:busy = $true; Set-ButtonsEnabled $false
        try {
            $output = & $sb @argsList *>&1
            foreach ($l in $output) { Add-Log $l.ToString() }
        } catch { Add-Log ("[ERROR] " + $_.Exception.Message) }
        $script:busy = $false; Set-ButtonsEnabled $true
        Refresh-Status
    }

    function Run-Auto {
        if ($script:busy) { return }
        $script:busy = $true; Set-ButtonsEnabled $false
        try {
            Add-Log '>> 一键自动切换：刷网络配置 + hosts 同步 ...'
            $output = Invoke-AutoConfig *>&1
            foreach ($l in $output) { Add-Log $l.ToString() }
            Add-Log '[OK] 自动切换完成（网络配置 + hosts 已刷新）。'
        } catch { Add-Log ("[ERROR] " + $_.Exception.Message) }
        $script:busy = $false; Set-ButtonsEnabled $true
        Refresh-Status
    }

    function Run-Static {
        $alias = Get-SelAlias
        if (-not $alias) { Add-Log '[ERROR] 请先在上方选择一个目标网卡。'; return }
        $ip = if ($script:ipFields['txtIp'].Text.Trim()) { $script:ipFields['txtIp'].Text.Trim() } else { $DefaultIP }
        $mask = if ($script:ipFields['txtMask'].Text.Trim()) { $script:ipFields['txtMask'].Text.Trim() } else { $DefaultMask }
        $gw = if ($script:ipFields['txtGw'].Text.Trim()) { $script:ipFields['txtGw'].Text.Trim() } else { $DefaultGateway }
        $dns1 = if ($script:ipFields['txtDns1'].Text.Trim()) { $script:ipFields['txtDns1'].Text.Trim() } else { $DefaultDNS1 }
        $dns2 = $script:ipFields['txtDns2'].Text.Trim()
        Run-Action -sb { param($a,$i,$m,$g,$d1,$d2)
            $adp = Get-NetAdapter -InterfaceAlias $a -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($adp) { Backup-Adapter $adp | ConvertTo-Json | Set-Content $BackupFile -Encoding UTF8 }
            Apply-Static $a $i $m $g $d1 $d2 $false
            Test-Connectivity $a
        } -argsList @($alias,$ip,$mask,$gw,$dns1,$dns2)
    }

    function Run-Dhcp {
        $alias = Get-SelAlias
        if (-not $alias) { Add-Log '[ERROR] 请先在上方选择一个目标网卡。'; return }
        Run-Action -sb { param($a)
            $adp = Get-NetAdapter -InterfaceAlias $a -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($adp) { Backup-Adapter $adp | ConvertTo-Json | Set-Content $BackupFile -Encoding UTF8 }
            Set-Dhcp $a
            Test-Connectivity $a
        } -argsList @($alias)
    }

    function Run-Restore {
        if ($script:busy) { return }
        $script:busy = $true; Set-ButtonsEnabled $false
        try {
            if (-not (Test-Path $BackupFile)) { Add-Log '[TIP] 尚未生成备份文件（还未切换过）。' }
            else {
                $bk = Get-Content $BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json
                $list = if ($bk -is [Array]) { $bk } else { @($bk) }
                foreach ($e in $list) {
                    if ($e.Dhcp) { Set-Dhcp $e.Alias }
                    else { $m = ConvertTo-DottedMask $e.Mask; Apply-Static $e.Alias $e.IP $m $e.Gateway $e.DNS1 $e.DNS2 $e.Wireless }
                    Add-Log ("[OK] 已恢复: " + $e.Alias)
                }
            }
        } catch { Add-Log ("[ERROR] " + $_.Exception.Message) }
        $script:busy = $false; Set-ButtonsEnabled $true
        Refresh-Status
    }

    $btnAuto.Add_Click({ Run-Auto })
    $btnStatus.Add_Click({ Refresh-Status })
    $btnClear.Add_Click({ $rtb.Clear() })
    $btnRefreshAdp.Add_Click({ Fill-Adapters })

    Refresh-Status
    Fill-Adapters
    Add-Log 'NetHostSync GUI 已就绪。点击「一键自动切换」执行核心集成动作，或选择网卡后做手动操作。'
    $form.ShowDialog() | Out-Null
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

# 图形界面入口（中文、经 GDI 渲染无残影）：-Gui 时直接拉起 WinForms，不再进入控制台菜单
if ($Gui) { Show-Gui; exit }

# ============================================================
# 交互主循环
# ============================================================
while ($true) {
    Clear-Screen
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "    NetHostSync  v$ScriptVersion  -  auto NIC switch + hosts sync" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    $adminOK = ($isAdmin -or $isSystem)
    $adminText = if ($adminOK) { 'admin [OK]' } else { 'NOT admin [X](no permission to modify network config,right-click"run as administrator")' }
    $adminColor = if ($adminOK) { 'Green' } else { 'Red' }
    Write-Host "  privilege:" -NoNewline
    Write-Host $adminText -ForegroundColor $adminColor
    $connAdapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.MediaConnectionState -eq 'Connected' -and -not (Test-Excluded $_) })
    $wiredN = @($connAdapters | Where-Object { -not (Test-Wireless $_) }).Count
    $wirelessN = @($connAdapters | Where-Object { Test-Wireless $_ }).Count
    $autoOn = $false
    try { $at = Get-ScheduledTask -TaskName 'NetworkConfigAutoSwitch' -ErrorAction SilentlyContinue; if ($at -and $at.State -ne 'Disabled') { $autoOn = $true } } catch {}
    Write-Host "  connections: wired $wiredN · wireless $wirelessN  | auto-switch: $(if ($autoOn) { 'enabled' } else { 'disabled' })"
    Write-Host "rule: wired -> default static IP; wireless -> dynamic (DHCP)."
    Write-Host "  1. auto-switch (wired->default static, wireless->DHCP, refresh hosts)"
    Write-Host "  2. set static IP (manually change defaults)"
    Write-Host "  3. set dynamic IP (DHCP)"
    Write-Host "  4. enable network-change auto-trigger (register scheduled task)"
    Write-Host "  5. disable network-change auto-trigger"
    Write-Host "  6. restore last config (from backup)"
    Write-Host "  7. diagnostics (read-only: show real adapter status, no changes)"
    Write-Host "  8. exit"
    Write-Host ""
    $choice = Read-Host "enter option [1/2/3/4/5/6/7/8]"
    try {
    switch ($choice) {
        '1' {
            $pa = Invoke-AutoConfig
            if (-not $Auto -and $pa) { Show-Result $pa }
        }
        '2' {
            $adapter = Get-ActiveAdapter
            if ($adapter -eq '__CANCEL__') { Write-Host "cancelled, returning to main menu." -ForegroundColor Yellow; Start-Sleep 1; continue }
            if (-not $adapter) { Write-Host "[ERROR] no connected network adapter detected." -ForegroundColor Red; Start-Sleep 2; continue }
            $bk = Backup-Adapter $adapter
            $bk | ConvertTo-Json | Set-Content $BackupFile -Encoding UTF8
            if (Set-StaticWithPrompt $adapter.InterfaceAlias) {
                Test-Connectivity $adapter.InterfaceAlias
                Show-Result $adapter.InterfaceAlias
            } else { Pause-Return }
        }
        '3' {
            $adapter = Get-ActiveAdapter
            if ($adapter -eq '__CANCEL__') { Write-Host "cancelled, returning to main menu." -ForegroundColor Yellow; Start-Sleep 1; continue }
            if (-not $adapter) { Write-Host "[ERROR] no connected network adapter detected." -ForegroundColor Red; Start-Sleep 2; continue }
            $bk = Backup-Adapter $adapter
            $bk | ConvertTo-Json | Set-Content $BackupFile -Encoding UTF8
            Set-Dhcp $adapter.InterfaceAlias
            Test-Connectivity $adapter.InterfaceAlias
            Show-Result $adapter.InterfaceAlias
        }
        '4' { Install-AutoTask; Pause-Return }
        '5' { Uninstall-AutoTask; Pause-Return }
        '6' { Restore-Backup; Pause-Return }
        '7' { Show-Diagnostics; Write-Host "`npress any key to return to main menu..." -NoNewline; $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown'); Write-Host "" }
        '8' { Write-Host "exited."; exit }
        default { Write-Host "[ERROR] invalid input, please choose again." -ForegroundColor Red; Start-Sleep 2 }
        }
    } catch {
        # 单选项执行出错时显示错误并返回主菜单，避免脚本静默终止导致窗口闪退
        Write-Host "`n[ERROR] error running that option, returned to main menu:" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
        Start-Sleep 3
    }
}
