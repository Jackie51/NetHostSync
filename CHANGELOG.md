# Changelog

本项目采用 [语义化版本](https://semver.org/lang/zh-CN/)（SemVer）雏形，并在每次发布记录日期与要点。

## [v0.1.0] —— 2026-08-05

首个开源整理版本。把原本的「笔记本 IP 一键切换 + hosts 自动同步」小工具，整理成轻量、零依赖（纯 PowerShell）的 Windows 工具，并补足工程化配套。

### Features
- **事件驱动的网络 → hosts 自动同步**：监听网络变化（插拔网线 / 切换 Wi-Fi / 手机热点），自动把 `hosts` 中指定服务域名指向当前活动 IPv4。
- **有线优先**：有线连接时套默认静态 IP，无线保持 DHCP；通过 `InterfaceMetric` 实现有线优先而不打断无线 DHCP 握手。
- **变更即更新**：网络环境变化时自动重算并刷新 hosts，不再固定假设某个 IP。
- **hosts 直接覆盖**：统一覆盖写入，不再生成 `hosts.*.bak` 备份；幂等，未变化时跳过。
- **VPN / 虚拟网卡排除**：默认排除 VPN、TAP、WireGuard、Cisco AnyConnect 等隧道/虚拟网卡，避免误改。
- **配置外置**：`config.json` 驱动默认 IP / 掩码 / 网关 / DNS / 优先级 / 排除规则 / hosts 目标域名，改参数不碰脚本。

### Engineering / 工程化
- 抽出无副作用的 `NetHostSync.psm1`（`Update-HostsLines`），让核心 hosts 变换逻辑可被离线测试。
- 新增 `tests/NetHostSync.Tests.ps1`（Pester 5.x）与 `tests/Verify.ps1`（无 Pester 依赖的等价断言脚本）。
- 新增 `PSScriptAnalyzerSettings.psd1`：静态分析只拦截 Error / Warning，纯风格类不阻断。
- 新增 `.github/workflows/ci.yml`：每次 push / PR 在 `windows-latest` 跑静态分析 + 测试。
- 双语文档：`README.md` / `README.en.md` / `CONTRIBUTING.md` / `TROUBLESHOOTING.md`，以及 `config.sample.json`、`hosts.sample` 示例。
- MIT 许可证。

### Fixes
- 修复 IP 替换时吞掉行首缩进的缺陷（原 `Substring` 实现会把 IP 后的首个分隔空格算进 rest）。
- 修复切网瞬间 hosts 探测拿到残留地址、注释行误判为已存在而不追加等问题（详见 `TROUBLESHOOTING.md`）。
