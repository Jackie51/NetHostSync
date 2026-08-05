# ============================================================
# NetHostSync 模块 —— 可离线单元测试的纯逻辑
#
# 把 update_hosts.ps1 中「无文件 / 无网络依赖」的 hosts 文本变换逻辑
# 单独抽出来，便于用 Pester 在任意环境（含 CI）下离线测试。
# 文件读写、IPv4 探测、提权等副作用仍留在 .ps1 主脚本中。
# ============================================================

# 仅对外导出纯变换函数；其余辅助函数仅模块内部使用。
Export-ModuleMember -Function Update-HostsLines

<#
.SYNOPSIS
    对 hosts 文件行集合做「未注释目标行替换 IP + 缺失追加」的纯变换。

.DESCRIPTION
    - 输入一组 hosts 行（字符串数组，不含文件读写）。
    - 仅修改「激活行（非空且不以 # 开头）」中命中 $Targets 的行：把该行首个 token（IP）替换为 $NewIP，其余（含内联注释、缩进）原样保留。
    - 注释行 / 空行原样保留。
    - 若某目标主机名在激活行中完全不存在（即使只出现在注释里），则在末尾追加 "$NewIP $target" 激活行。
    - 不在此函数内做幂等判断（调用方可自行比对），也不写盘。

.PARAMETER Lines
    原始 hosts 行数组。

.PARAMETER Targets
    需要随网络更新的目标主机名数组。

.PARAMETER NewIP
    要写入的当前活动 IPv4。

.OUTPUTS
    PSCustomObject —— @{ Lines = string[]（变换后行）; Changes = string[]（本次变更人类可读描述） }
#>
function Update-HostsLines {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Lines,
        [Parameter(Mandatory = $true)]
        [string[]]$Targets,
        [Parameter(Mandatory = $true)]
        [string]$NewIP
    )

    $newLines = @()
    $changes  = @()
    $seen     = @{}   # 目标主机名是否已在「激活行」中出现（注释行不算）

    foreach ($line in $Lines) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) {
            # 空行 / 注释行：原样保留（注释中出现的目标主机名不算“已存在”）
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
            # 关键：保留行首到 IP 起始位置的前缀（缩进/制表符），并在 IP 后保留原分隔符，
            # 避免 Substring(IndexOf+len) 把首个分隔空格算进 rest 而吞掉前导缩进。
            $idx   = $line.IndexOf($ipTok)
            $prefix = $line.Substring(0, $idx)              # 行首到 IP 前的所有字符（缩进等）
            $rest  = $line.Substring($idx + $ipTok.Length)  # IP 之后（含原分隔符）
            $newLines += ($prefix + $NewIP + $rest)
            $changes += ("UPDATE: $ipTok -> $NewIP (" + ($matched -join ', ') + ")")
        } else {
            $newLines += $line
        }
    }

    # 对完全未在激活行出现的目标主机名，追加激活行（确保始终含指向当前 IP 的生效映射）
    foreach ($t in $Targets) {
        if (-not $seen[$t]) {
            $newLines += "$NewIP $t"
            $changes += ("ADD: $NewIP $t")
        }
    }

    return [PSCustomObject]@{
        Lines   = $newLines
        Changes = $changes
    }
}
