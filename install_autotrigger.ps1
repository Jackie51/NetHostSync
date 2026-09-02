# install_autotrigger.ps1 - 一次性注册 NetHostSync 自动触发计划任务
# 用法：右键本文件 -> 以管理员身份运行（必须管理员，否则会提示并退出）
$ErrorActionPreference = 'Stop'
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ScriptPath = Join-Path $ScriptDir 'network_config.ps1'
$cfgFile    = Join-Path $ScriptDir 'config.json'
$LogFile    = Join-Path $ScriptDir 'install_autotrigger.log'
$out = [System.Collections.ArrayList]::new()
function Log($m){ $out.Add($m); "$m" | Add-Content $LogFile -Encoding UTF8 }

# 1) 管理员自检
$id      = [Security.Principal.WindowsIdentity]::GetCurrent()
$princ   = [Security.Principal.WindowsPrincipal]$id
$isAdmin = $princ.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isSys   = ($id.User.Value -eq 'S-1-5-18') -or ($id.Name -eq 'NT AUTHORITY\SYSTEM')
if (-not ($isAdmin -or $isSys)) {
    Log '[ERROR] 本脚本必须以管理员身份运行。请右键本文件 -> 以管理员身份运行，再点 UAC 确认。'
    Log '（普通用户直接双击会因权限不足无法注册计划任务。）'
    $out -join "`n" | Set-Content -Encoding UTF8 $LogFile
    Write-Host ($out -join "`n")
    Read-Host '按回车退出'
    exit 1
}

# 2) 准备参数
$taskName = 'NetworkConfigAutoSwitch'
$psExe    = (Get-Command powershell.exe).Source
if (-not (Test-Path $ScriptPath)) { Log "[ERROR] 找不到 $ScriptPath，请确认本脚本与 network_config.ps1 在同一目录。"; throw }
$AutoPollMinutes = 5
if (Test-Path $cfgFile) {
    try { $c = Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json; if ($c.AutoPollMinutes) { $AutoPollMinutes = $c.AutoPollMinutes } } catch {}
}
Log "identity: $(if($isSys){'SYSTEM'}else{'Admin'}) | script: $ScriptPath | poll: $AutoPollMinutes min"

# 3) 启用事件通道
try {
    & wevtutil.exe sl "Microsoft-Windows-NetworkProfile/Operational" /e:true 2>&1 | Out-Null
    $ch = & wevtutil.exe gl "Microsoft-Windows-NetworkProfile/Operational" 2>&1 | Out-String
    if ($ch -match 'enabled:\s*true') { Log '[OK] event channel NetworkProfile/Operational enabled.' }
    else { Log '[WARN] event channel still NOT enabled, auto-trigger events may not fire. Enable it manually in Event Viewer.' }
} catch { Log "[WARN] failed to enable event channel: $_" }

# 4) 清理旧/脏任务
try {
    $t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($t) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop; Log "[OK] removed existing task $taskName (clean re-register)." }
    @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskName -ne $taskName -and $_.Actions -and (
            ($_.Actions.Execute -like '*network_config.ps1*') -or
            ($_.Actions.Arguments -like '*network_config.ps1*') -or
            ($_.Actions.Execute -like '*One-click switch*') -or
            ($_.Actions.Arguments -like '*One-click switch*')
        )
    }) | ForEach-Object { Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction Stop; Log "[OK] removed stale task $($_.TaskName)." }
} catch { Log "[WARN] cleanup: $_" }

# 5) 注册
try {
    $action   = New-ScheduledTaskAction -Execute $psExe -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -Auto"
    $principal= New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $evtClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
    $sub10000 = '<QueryList><Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"><Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[(EventID=10000)]]</Select></Query></QueryList>'
    $sub10001 = '<QueryList><Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"><Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[(EventID=10001)]]</Select></Query></QueryList>'
    $evt10000 = New-CimInstance -CimClass $evtClass -Property @{ Subscription = $sub10000; Enabled = $true } -ClientOnly
    $evt10001 = New-CimInstance -CimClass $evtClass -Property @{ Subscription = $sub10001; Enabled = $true } -ClientOnly
    $logonTrig= New-ScheduledTaskTrigger -AtLogOn
    $bootTrig = New-ScheduledTaskTrigger -AtStartup
    $pollTrig = New-ScheduledTaskTrigger -Once -At "2026-01-01T00:00:00" -RepetitionInterval (New-TimeSpan -Minutes $AutoPollMinutes) -RepetitionDuration (New-TimeSpan -Days 3650)
    $triggers = @($evt10000, $evt10001, $logonTrig, $bootTrig, $pollTrig)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew -Priority 7
    $result = Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Trigger $triggers -Settings $settings -Description "network change auto-switch config and refresh hosts (NetHostSync)" -Force
    if ($result) {
        Log "[OK] scheduled task registered: $taskName"
        $info = Get-ScheduledTaskInfo -TaskName $taskName
        Log "  triggers: $(($triggers | ForEach-Object { $_.CimClass.CimClassName }) -join ', ')"
        Log "  LastRunTime: $($info.LastRunTime) | LastTaskResult: $($info.LastTaskResult) | NextRunTime: $($info.NextRunTime)"
        Log "  -> 网络插拔将自动触发；事件漏抓时每 $AutoPollMinutes 分钟兜底一次。"
    } else {
        Log "[FAIL] Register-ScheduledTask returned no task object."
    }
} catch {
    Log "[FAIL] registration error: $($_.Exception.Message)"
}

# 6) 立刻跑一次验证链路（插网线后本就该如此；这里确认 -Auto 能写 hosts）
Log "=== verification: run -Auto once to confirm hosts pipeline works ==="
try {
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -Auto 2>&1 | ForEach-Object { Log "  AUTO> $_" }
} catch { Log "  AUTO exception: $_" }

Log "=== DONE. Full log at $LogFile ==="
$out -join "`n" | Set-Content -Encoding UTF8 $LogFile
Write-Host ($out -join "`n")
Read-Host '按回车退出'
