# 贡献指南 / Contributing

感谢参与 NetHostSync 的改进！本工具是零依赖纯 PowerShell 小工具，提交前请遵循以下约定。

## 开发与测试 / Development & Tests

核心 `hosts` 文本变换逻辑已从 `update_hosts.ps1` 抽离到 **`NetHostSync.psm1`**（`Update-HostsLines`），无文件/网络副作用，可用 Pester 离线测试。

### 跑测试 / Running tests

- **有 Pester（推荐）**：
  ```powershell
  Install-Module Pester -Force -Scope CurrentUser
  Invoke-Pester -Path tests/NetHostSync.Tests.ps1
  ```
- **无 Pester / 受限环境**：运行等价断言脚本，退出码 0 表示全部通过：
  ```powershell
  powershell -File tests/Verify.ps1
  ```

### 静态分析 / Static analysis

```powershell
Install-Module PSScriptAnalyzer -Force -Scope CurrentUser
Invoke-ScriptAnalyzer -Path . -Recurse -Settings PSScriptAnalyzerSettings.psd1
```

仅 **Error** 级问题会阻断 CI；**Warning** 级仅打印提示、不导致构建失败。纯风格类规则未列入 `IncludeRules`，本就不参与检查。

### CI

每次 push / PR 会在 `windows-latest` 上运行 `.github/workflows/ci.yml`：安装 Pester + PSScriptAnalyzer → 跑静态分析（仅 Error 失败，Warning 仅提示）→ 跑 Pester 测试（Pester 不可用时回退到 `tests/Verify.ps1`）。

## 提交约定 / Commit guidelines

- 修改 `hosts` 变换逻辑时，**务必同步更新 `NetHostSync.psm1` 与 `tests/Verify.ps1` 中的内联回退实现**（二者逻辑须一致）。
- 新增行为请补对应的 Pester 用例（或在 `Verify.ps1` 中补等价断言）。
- 改动 `config.json` 字段时，同步更新 `README.md` 与 `README.en.md` 的字段说明。
- 提交信息用中文或英文均可，建议说明「为什么」而非只是「做了什么」。

## 安全边界 / Safety boundary

本工具的真实副作用（改 hosts、注册/卸载计划任务、可选改网卡）**只发生在用户本机运行脚本或自动触发时**。提交代码时请勿引入会自动修改用户系统的逻辑；所有系统级改动必须显式、且仅在用户运行主脚本时发生。

## 文档 / Docs

- 中文文档：`README.md`、`TROUBLESHOOTING.md`、`使用说明.md`
- 英文文档：`README.en.md`

改功能时请保持两份 README 同步。
