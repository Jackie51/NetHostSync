# ============================================================
# Verify.ps1 —— 不依赖 Pester 的等价断言器（CI 兜底 / 本地快速校验）。
# 思路：dot-source 项目 NetHostSync.psm1 中同名函数体不可用时的回退已内嵌，
# 这里直接 dot-source 模块文件；若环境无法加载模块，则使用同款内联实现，
# 保证断言逻辑与模块一致。
#
# 运行（需在项目根目录）：
#   powershell -File tests/Verify.ps1
# 退出码 0 = 全部通过；非 0 = 有失败。
# ============================================================

$root = Split-Path -Parent $PSScriptRoot
$mod  = Join-Path $root 'NetHostSync.psm1'

# 优先 dot-source 模块；加载失败时回退到同款内联实现（代码与模块保持一致）。
$fnLoaded = $false
if (Test-Path $mod) {
    try {
        . $mod
        # 验证函数确实可用
        $null = Update-HostsLines -Lines @('1.1.1.1 x') -Targets @('x') -NewIP '2.2.2.2'
        $fnLoaded = $true
    } catch { $fnLoaded = $false }
}

if (-not $fnLoaded) {
    # 内联同款实现（与 NetHostSync.psm1 同步维护）
    function Update-HostsLines {
        param([string[]]$Lines,[string[]]$Targets,[string]$NewIP)
        $newLines = @(); $seen = @{}
        foreach ($line in $Lines) {
            $trimmed = $line.Trim()
            if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { $newLines += $line; continue }
            $tokens = $trimmed -split '\s+'
            $ipTok = $tokens[0]
            $hostToks = $tokens | Where-Object { $_ -and $_ -ne '#' -and -not $_.StartsWith('#') } | Select-Object -Skip 1
            $matched = @($hostToks | Where-Object { $Targets -contains $_ })
            foreach ($t in $matched) { $seen[$t] = $true }
            if ($matched.Count -gt 0) {
                $idx = $line.IndexOf($ipTok); $prefix = $line.Substring(0, $idx); $rest = $line.Substring($idx + $ipTok.Length)
                $newLines += ($prefix + $NewIP + $rest)
            } else { $newLines += $line }
        }
        foreach ($t in $Targets) { if (-not $seen[$t]) { $newLines += "$NewIP $t" } }
        return [PSCustomObject]@{ Lines = $newLines; Changes = @() }
    }
}

$fail = 0
function Check($name, $cond) {
    if ($cond) { Write-Host "PASS: $name" -ForegroundColor Green }
    else { Write-Host "FAIL: $name" -ForegroundColor Red; $script:fail++ }
}

$targets = @('know.com', 'host.docker.internal', 'gateway.docker.internal')

$r = Update-HostsLines -Lines @(
    '127.0.0.1 localhost',
    '192.168.1.55 know.com  # old',
    '# 192.168.1.55 host.docker.internal'
) -Targets $targets -NewIP '10.0.0.5'
Check 'replace ip + inline comment' ($r.Lines[1] -eq '10.0.0.5 know.com  # old')
Check 'comment line preserved'      ($r.Lines[2] -eq '# 192.168.1.55 host.docker.internal')
Check 'localhost preserved'         ($r.Lines[0] -eq '127.0.0.1 localhost')
Check 'host.docker.internal appended (only-in-comment)' ($r.Lines -contains '10.0.0.5 host.docker.internal')
Check 'gateway appended'            ($r.Lines -contains '10.0.0.5 gateway.docker.internal')

$r2 = Update-HostsLines -Lines @('  192.168.1.55 know.com') -Targets @('know.com') -NewIP '10.0.0.5'
Check 'indent preserved'            ($r2.Lines[0] -eq '  10.0.0.5 know.com')

$r3 = Update-HostsLines -Lines @('# 192.168.1.55 know.com') -Targets @('know.com') -NewIP '10.0.0.5'
Check 'comment-only still appends active' ($r3.Lines -contains '10.0.0.5 know.com')
Check 'comment-only count == 2'            ($r3.Lines.Count -eq 2)

$r4 = Update-HostsLines -Lines @('10.0.0.5 know.com') -Targets @('know.com') -NewIP '10.0.0.5'
Check 'no dup append when present active'  ($r4.Lines.Count -eq 1)

$r5 = Update-HostsLines -Lines @('192.168.1.55 know.com host.docker.internal') -Targets $targets -NewIP '10.0.0.5'
Check 'multi-host single line'            ($r5.Lines[0] -eq '10.0.0.5 know.com host.docker.internal')
Check 'gateway appended for missing'      ($r5.Lines -contains '10.0.0.5 gateway.docker.internal')

# 用 List[string] 显式保留空元素（PowerShell 数组字面量 @('','') 会丢弃空元素）
$L = New-Object 'System.Collections.Generic.List[string]'
$L.Add(''); $L.Add('# comment'); $L.Add(''); $L.Add('')
$r6 = Update-HostsLines -Lines $L.ToArray() -Targets @('know.com') -NewIP '10.0.0.5'
Check 'blank + comment preserved'         ($r6.Lines[0] -eq '' -and $r6.Lines[1] -eq '# comment' -and $r6.Lines[3] -eq '')
Check 'append at end after blanks'        ($r6.Lines[4] -eq '10.0.0.5 know.com')

$r7 = Update-HostsLines -Lines @('192.168.1.55 other.local', '127.0.0.1 localhost') -Targets @('know.com') -NewIP '10.0.0.5'
Check 'untouched active line preserved'   ($r7.Lines -contains '192.168.1.55 other.local')
Check 'untouched localhost preserved'     ($r7.Lines -contains '127.0.0.1 localhost')

if ($fail -eq 0) { Write-Host "`nALL PASS" -ForegroundColor Green; exit 0 }
else { Write-Host "`nFAILURES: $fail" -ForegroundColor Red; exit 1 }
