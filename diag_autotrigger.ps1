# diag_autotrigger.ps1 - 诊断"网络变化为何不自动触发 hosts 更新"
# 用法：在另一台电脑（普通用户即可）运行
#   powershell -NoProfile -ExecutionPolicy Bypass -File ".\diag_autotrigger.ps1"
# 先跑一次看现状；然后拔掉网线/切 Wi-Fi，等 10 秒，再跑一次对比第3、4节。
$taskName = 'NetworkConfigAutoSwitch'

Write-Host "===== 1. 计划任务状态 =====" -ForegroundColor Cyan
$t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if (-not $t) {
    Write-Host "  [缺失] 任务 $taskName 不存在！请重新跑 network_config.ps1 菜单4 注册。" -ForegroundColor Red
} else {
    $i = Get-ScheduledTaskInfo -TaskName $taskName
    Write-Host "  存在：是"
    Write-Host ("  上次运行时间：$($i.LastRunTime)")
    Write-Host ("  上次结果码：$($i.LastTaskResult)  (0=成功 / 267011=从未运行 / 其他=出错)")
    Write-Host ("  下次运行时间：$($i.NextRunTime)  (N/A 对事件触发器正常)")
    $t.Triggers | ForEach-Object { Write-Host ("  触发器类型：" + $_.GetType().Name) }
    $t.Actions | ForEach-Object { Write-Host ("  动作：$( $_.Execute ) $( $_.Arguments )") }
}

Write-Host "`n===== 2. 事件通道 NetworkProfile/Operational =====" -ForegroundColor Cyan
try {
    $ch = & wevtutil.exe gl "Microsoft-Windows-NetworkProfile/Operational" 2>&1 | Out-String
    if ($ch -match 'enabled:\s*true') { Write-Host "  通道已启用 OK" -ForegroundColor Green }
    else { Write-Host "  通道未启用 X —— 事件触发器永不点火！请手动在事件查看器启用该通道。" -ForegroundColor Red }
} catch { Write-Host "  读取通道状态失败：$_" -ForegroundColor Yellow }

Write-Host "`n===== 3. 最近 15 条 NetworkProfile 事件（含 ID）=====" -ForegroundColor Cyan
try {
    & wevtutil.exe qe "Microsoft-Windows-NetworkProfile/Operational" /c:15 /rd:true /f:text 2>&1 | ForEach-Object { Write-Host ("  " + $_.ToString().Trim()) }
} catch { Write-Host "  读取事件失败：$_" -ForegroundColor Yellow }

Write-Host "`n===== 4. 日志 network_switch.log 末尾 15 行 =====" -ForegroundColor Cyan
$log = Join-Path $PSScriptRoot 'network_switch.log'
if (Test-Path $log) { Get-Content $log -Tail 15 | ForEach-Object { Write-Host ("  " + $_) } }
else { Write-Host "  [无] 未找到日志（说明 -Auto 从未成功跑过）。" -ForegroundColor Yellow }

Write-Host "`n[操作建议]"
Write-Host "  1) 把上面 1/2/3 节结果完整发回（尤其第3节：看拔线时是否真的出现 EventID=10001）。"
Write-Host "  2) 触发测试：先跑一次本脚本留底；然后插上网线再拔掉（或拔掉再插上），等 10 秒，再跑一次，"
Write-Host "     对比两次第3节事件、第4节日志是否新增。注意：必须『注册之后』再产生网络变化，新触发器才抓得到。"
Write-Host "  3) 若事件触发偶发漏抓也没关系：新版本已加『每5分钟定时兜底』，拔线后至多5分钟内 hosts 会自动修正。"
Write-Host "     验证定时兜底：拔线后直接等 5~6 分钟，再查 network_switch.log 是否出现新的「自动模式启动」与无线 IP。"
