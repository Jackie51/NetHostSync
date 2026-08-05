# ============================================================
# Pester 测试：覆盖 hosts 文本变换（NetHostSync 模块）的核心逻辑。
# 运行：
#   Invoke-Pester -Path tests/NetHostSync.Tests.ps1
# 或（无 Pester 时）用 tests/Verify.ps1 做等价断言。
# ============================================================

Describe 'Update-HostsLines' {

    BeforeAll {
        $module = Join-Path $PSScriptRoot '..' 'NetHostSync.psm1'
        Import-Module $module -Force
        # 注意：Pester 5 的 discovery 与 execution 是分离的作用域，
        # Describe 顶层（BeforeAll 之外）的变量在执行阶段的 It 块中不可见，
        # 因此共享变量必须放在 BeforeAll 内。
        $targets = @('know.com', 'host.docker.internal', 'gateway.docker.internal')
    }

    It '替换激活行的 IP，并保留行内联注释' {
        $r = Update-HostsLines -Lines @(
            '127.0.0.1 localhost',
            '192.168.1.55 know.com  # old',
            '# 192.168.1.55 host.docker.internal'
        ) -Targets $targets -NewIP '10.0.0.5'

        $r.Lines[1] | Should -Be '10.0.0.5 know.com  # old'
        $r.Lines[2] | Should -Be '# 192.168.1.55 host.docker.internal'
        $r.Lines[0] | Should -Be '127.0.0.1 localhost'
    }

    It '保留行首缩进（前置空格）' {
        $r = Update-HostsLines -Lines @('  192.168.1.55 know.com') -Targets @('know.com') -NewIP '10.0.0.5'
        $r.Lines[0] | Should -Be '  10.0.0.5 know.com'
    }

    It '目标主机名仅出现在注释行时，仍追加为激活行' {
        $r = Update-HostsLines -Lines @('# 192.168.1.55 know.com') -Targets @('know.com') -NewIP '10.0.0.5'
        $r.Lines -contains '10.0.0.5 know.com' | Should -BeTrue
        $r.Lines.Count | Should -Be 2
    }

    It '完全不存在的目标主机名追加到末尾' {
        $r = Update-HostsLines -Lines @('127.0.0.1 localhost') -Targets $targets -NewIP '10.0.0.5'
        $r.Lines -contains '10.0.0.5 know.com'              | Should -BeTrue
        $r.Lines -contains '10.0.0.5 host.docker.internal' | Should -BeTrue
        $r.Lines -contains '10.0.0.5 gateway.docker.internal' | Should -BeTrue
    }

    It '已存在的激活行不重复追加' {
        $r = Update-HostsLines -Lines @('10.0.0.5 know.com') -Targets @('know.com') -NewIP '10.0.0.5'
        $r.Lines.Count | Should -Be 1
    }

    It '同一行含多个目标主机名时整行替换 IP，仅缺失的追加' {
        $r = Update-HostsLines -Lines @('192.168.1.55 know.com host.docker.internal') -Targets $targets -NewIP '10.0.0.5'
        $r.Lines[0] | Should -Be '10.0.0.5 know.com host.docker.internal'
        $r.Lines -contains '10.0.0.5 gateway.docker.internal' | Should -BeTrue
    }

    It '空行与注释行原样保留，且追加发生在末尾' {
        # 用 List<string> 构造含空元素的行数组（避免 @('',...) 在 Pester 作用域中空字符串被吞）
        $L = New-Object 'System.Collections.Generic.List[string]'
        $L.Add(''); $L.Add('# comment'); $L.Add(''); $L.Add('')
        $r = Update-HostsLines -Lines $L.ToArray() -Targets @('know.com') -NewIP '10.0.0.5'
        $r.Lines.Count | Should -Be 5
        $r.Lines[1] | Should -Be '# comment'
        $r.Lines[4] | Should -Be '10.0.0.5 know.com'
        # 空字符串 .Length 为 0（$null 会抛异常，便于定位根因）
        $r.Lines[0].Length | Should -Be 0
        $r.Lines[2].Length | Should -Be 0
        $r.Lines[3].Length | Should -Be 0
    }

    It '非空行与注释行原样保留（对照：验证函数逻辑无误）' {
        $r = Update-HostsLines -Lines @('LINE0', '# comment', 'LINE2', 'LINE3') -Targets @('know.com') -NewIP '10.0.0.5'
        $r.Lines.Count | Should -Be 5
        $r.Lines[0] | Should -Be 'LINE0'
        $r.Lines[1] | Should -Be '# comment'
        $r.Lines[2] | Should -Be 'LINE2'
        $r.Lines[3] | Should -Be 'LINE3'
        $r.Lines[4] | Should -Be '10.0.0.5 know.com'
    }

    It '不触碰未命中任何目标的激活行' {
        $r = Update-HostsLines -Lines @('192.168.1.55 other.local', '127.0.0.1 localhost') -Targets @('know.com') -NewIP '10.0.0.5'
        $r.Lines -contains '192.168.1.55 other.local' | Should -BeTrue
        $r.Lines -contains '127.0.0.1 localhost'      | Should -BeTrue
    }

    It '返回的 Changes 记录每次 UPDATE/ADD' {
        $r = Update-HostsLines -Lines @('192.168.1.55 know.com') -Targets $targets -NewIP '10.0.0.5'
        ($r.Changes | Where-Object { $_ -like 'UPDATE:*' }).Count | Should -BeGreaterThan 0
        ($r.Changes | Where-Object { $_ -like 'ADD:*' }).Count    | Should -BeGreaterThan 0
    }
}
