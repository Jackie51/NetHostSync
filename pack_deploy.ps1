# ============================================================
# pack_deploy.ps1 —— 打包 NetHostSync 最小部署集
# 用法（项目根目录运行）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File pack_deploy.ps1
# 产出：dist\NetHostSync-Deploy\  （可直接整体复制到目标机本地目录）
# 说明：仅收集运行必需文件 + 部署清单，不含 tests/、文档、排障脚本(可选附带)。
# ============================================================
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$out  = Join-Path $root 'dist\NetHostSync-Deploy'

# 清空旧产物，保证干净
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Path $out -Force | Out-Null

# 最小核心文件（与 DEPLOY.md 中"包含文件"保持一致）
$core = @(
    'network_config.ps1',
    'update_hosts.ps1',
    'NetHostSync.psm1',
    'config.json',          # 运行配置（个人参数，不进版本库，但部署时需要）
    'config.sample.json',   # 配置模板
    'NetHostSync.bat',         # 双击启动菜单（英文 ASCII，无残影）
    'deploy\DEPLOY.md'      # 部署清单（复制到包内根）
)

# 可选附带：排障脚本（自动触发异常时很有用，体积很小，默认带上）
$optional = @('diag_autotrigger.ps1')

$missing = @()
foreach ($rel in ($core + $optional)) {
    $src = Join-Path $root $rel
    if (-not (Test-Path $src)) { $missing += $rel; continue }
    # DEPLOY.md 复制后落到包根（去掉 deploy\ 前缀）
    if ($rel -eq 'deploy\DEPLOY.md') {
        Copy-Item $src -Destination (Join-Path $out 'DEPLOY.md') -Force
    } else {
        Copy-Item $src -Destination $out -Force
    }
}

Write-Host "已打包到: $out" -ForegroundColor Green
Get-ChildItem $out | Sort-Object Name | ForEach-Object {
    Write-Host ("  " + $_.Name) -ForegroundColor Cyan
}
if ($missing.Count -gt 0) {
    Write-Host ("警告：以下文件未找到，未打包 -> " + ($missing -join ', ')) -ForegroundColor Yellow
}
