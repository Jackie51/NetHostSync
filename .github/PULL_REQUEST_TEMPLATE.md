# Pull Request

## 改动说明 / What changed
<!-- 简述这次 PR 做了什么、为什么 -->

## 关联 Issue / Related issue
<!-- 例如 Fixes #12 -->

## 检查清单 / Checklist
- [ ] 文档（README / TROUBLESHOOTING）已同步更新
- [ ] 修改了 `hosts` 变换逻辑时，已同步更新 `NetHostSync.psm1` 与 `tests/Verify.ps1` 的内联回退实现
- [ ] 本地已运行测试（有 Pester 跑 `Invoke-Pester tests/NetHostSync.Tests.ps1`；无 Pester 跑 `powershell -File tests/Verify.ps1`，退出码应为 0）
- [ ] 未引入任何会自动修改用户系统的隐蔽逻辑
- [ ] 未提交 `config.json`、`.workbuddy/`、日志等本地专属文件

## 测试记录 / Test evidence
<!-- 贴一下 Verify.ps1 或 Pester 的输出（首尾几行即可） -->
