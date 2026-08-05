# NetHostSync —— 网络切换自动同步 hosts

> English documentation: [README.en.md](./README.en.md) ｜ 贡献指南: [CONTRIBUTING.md](./CONTRIBUTING.md)

轻量、零依赖（纯 PowerShell）的 Windows 小工具：监听网络变化（插拔网线 / 切换 Wi-Fi / 手机热点），自动把 `hosts` 中指定服务域名指向**当前活动 IPv4**。适合用 Docker Desktop、本地服务，且经常在多种网络之间切换的开发者。

## 它能做什么

- 网络连接方式变更时，自动更新 `hosts` 中指定的若干域名条目，使其指向当前正在使用的 IPv4。
- 有线 / 无线 / 手机热点**同时连接**时，优先选用有线网络的 IPv4（如有线）。
- 仅修改 `hosts` 中**未注释（激活）**的行，注释与其他内容原样保留；未发现的目标域名自动追加。
- 网络配置部分（可选）：插线时给有线网卡套默认静态 IP，无线恒为 DHCP；切换不中断 Windows 自身 DHCP 续租。
- 可注册为系统计划任务，完全后台、静默运行（SYSTEM 身份）。

## 适用场景

- 用 Docker Desktop / 本地服务，且经常在有线、家庭 Wi-Fi、手机热点之间切换的开发者。
- 服务通过自定义域名（如 `know.com`）或 `host.docker.internal` 访问，IP 一变就解析失败。
- 想让 `hosts` 随网络环境自动跟随，不必手动改。

## 系统要求

- Windows 10 / 11
- PowerShell 5.1 或更高（系统自带）
- 修改 `hosts`、注册计划任务需要管理员权限（自动触发以 SYSTEM 运行，无需交互提权）

## 安装

把以下文件放在**同一目录**即可（无需安装任何依赖）：

- `network_config.ps1` —— 网络配置 + 自动触发主脚本
- `update_hosts.ps1` —— hosts 同步脚本
- `config.json` —— 配置文件（首次运行自动生成；想知道字段含义见 [`config.sample.json`](./config.sample.json)）
- `网络配置.bat` / `更新hosts.bat` —— 可选启动器

> 想先看清楚 `hosts` 会被怎样处理？参考 [`hosts.sample`](./hosts.sample)。

## 配置（config.json）

所有可调参数集中在 `config.json`，无需改脚本。字段说明：

- `HostsTargets`：数组，要随网络环境更新的 `hosts` 域名列表（默认三项）。
- `DefaultIP` / `DefaultMask` / `DefaultGateway` / `DefaultDNS1` / `DefaultDNS2`：有线静态默认值。
- `WiredMetric` / `WirelessMetric`：接口优先级（数值越小越优先；有线 10 < 无线 20，确保同时连接时优先走有线）。
- `ExcludeAdapters`：正则，名称命中的网卡（VPN / 虚拟网卡）不纳入管理，避免误改隧道 IP。
- `UpdateHostsOnAuto`：自动触发时是否同步刷新 hosts（true / false）。
- `UpdateHostsScript`：hosts 脚本文件名（一般不动）。

提示：当前 `ExcludeAdapters` 用字面空格匹配「WAN Miniport」「Check Point」。如需更宽松（匹配任意空白），可在 `ExcludeAdapters` 中用 `\s*` 代替空格（注意 JSON 中每个反斜杠需写成两个）。

## 用法

### 交互菜单

双击 `网络配置.bat`（或右键以管理员运行 `network_config.ps1`），菜单：

- `1` 自动切换（有线→默认静态，无线→DHCP，并刷新 hosts）
- `2` 设置有线静态
- `3` 设置无线 DHCP
- `4` 启用网络变化自动触发（注册计划任务）
- `5` 停用自动触发
- `6` 恢复上一次网卡配置（backup.json）
- `7` 诊断（只读）
- `8` 退出

### 命令行

- 网络自动切换（供计划任务调用）：`powershell -File network_config.ps1 -Auto`
- 注册自动触发：`network_config.ps1 -InstallAuto`
- 卸载自动触发：`network_config.ps1 -UninstallAuto`
- 只读诊断：`network_config.ps1 -Diag`

### hosts 同步

- 手动刷新：右键以管理员运行 `更新hosts.bat`（或直接 `update_hosts.ps1`）
- 只读诊断（不需管理员）：`powershell -File update_hosts.ps1 -Diag`
- 临时指定条目（不写配置）：`powershell -File update_hosts.ps1 -HostEntries a.local,b.local`

## 自动触发（计划任务）

- 注册后，系统监听 `Microsoft-Windows-NetworkProfile/Operational` 事件（网络连接 10000 与断开 10001），任何联网方式变化都会触发。
- 以 SYSTEM 身份运行「网络自动切换 -Auto」，完成后自动调用 `update_hosts.ps1` 刷新 hosts。
- 注册时会自动启用被禁用的事件通道（否则触发器永不点火）。
- 卸载：菜单 `5` 或 `-UninstallAuto`。该操作会清理同名任务及任何指向本目录脚本的残留任务，不会累积重复任务。

## ⚠️ 安全说明（请务必阅读）

本工具会改动你的系统，但范围明确且局限：

- **【会改】** `C:\Windows\System32\drivers\etc\hosts`：把 `HostsTargets` 指定的域名 IP 改写为当前活动 IPv4（仅未注释行，注释/其他不动）。**直接覆盖写入，不生成备份文件**。
- **【会改】** 计划任务：注册/卸载名为 `NetworkConfigAutoSwitch` 的系统任务（`/RU SYSTEM`）。
- **【可选改】** 网络适配器：仅在「自动切换 / 菜单 1」时，给已连接的有线网卡套静态 IP、给残留静态的无线网卡恢复 DHCP（幂等，不重复下发，不打断 DHCP 续租）。
- **【不会改】** 不安装驱动、不修改系统注册表、不触碰 `hosts` 之外的系统文件；`hosts` 改写只发生在你运行脚本或自动触发时。
- **【权限】** 修改 `hosts` 与注册计划任务需管理员 / SYSTEM。交互模式会自动请求 UAC 提权；自动触发以 SYSTEM 运行（SYSTEM 下不弹 UAC，直接执行）。
- **【回退】** `hosts` 无备份，若需还原：手动编辑 `hosts` 把那几行 IP 改回目标值，或先 `-Diag` 查看当前值。网卡 IP 可经菜单 `6` 一键恢复（`backup.json`，与本工具其他逻辑无关，保留未动）。
- 注册前会自动清理早期失败尝试遗留的同名 / 脏任务。

## 日志

- `network_switch.log`：网络切换与自动触发记录。
- `update_hosts.log`：每次 hosts 刷新的明细（探测到的 IP、更新 / 追加 / 跳过）。
- 排障时把这两个日志附上，便于定位。

## 常见问题

- **自动触发没反应？** 先查 `network_switch.log` 是否有「自动模式启动」判断任务是否点火；再查 `update_hosts.log` 判断 IP 探测 / 写入。详见 `TROUBLESHOOTING.md`。
- **无线每次 IP 不固定？** 无需担心，脚本实时探测当前地址，始终与网络环境一致。
- **会影响 VPN 吗？** 不会。VPN / 虚拟网卡已被 `ExcludeAdapters` 排除，不在处理范围内。

## 故障排查

见 `TROUBLESHOOTING.md`。

## 开发与测试

最易出错的 `hosts` 文本变换逻辑已从 `update_hosts.ps1` 抽离到 **`NetHostSync.psm1`**（`Update-HostsLines`），无文件/网络副作用，可用 Pester 离线测试。

- **有 Pester（推荐）**：
  ```powershell
  Install-Module Pester -Force -Scope CurrentUser
  Invoke-Pester -Path tests/NetHostSync.Tests.ps1
  ```
- **无 Pester / 受限环境**：运行等价断言脚本，退出码 0 表示全部通过：
  ```powershell
  powershell -File tests/Verify.ps1
  ```
- 静态分析：`Invoke-ScriptAnalyzer -Path . -Recurse -Settings PSScriptAnalyzerSettings.psd1`
- CI：`.github/workflows/ci.yml` 在 `windows-latest` 上每次 push / PR 跑 PSScriptAnalyzer（仅 Error/Warning 失败）+ Pester 测试（Pester 不可用时回退 `tests/Verify.ps1`）。

## 许可证

MIT —— 见 `LICENSE`。
