# NetHostSync 部署清单

本目录是 NetHostSync 的**最小部署集**,可直接整体复制到目标 Windows 电脑的本地目录使用。

## 包含文件

| 文件 | 作用 |
|------|------|
| `network_config.ps1` | 主程序:交互菜单 + `-Auto` 自动模式 + 注册/卸载计划任务 |
| `update_hosts.ps1` | hosts 刷新,被主程序在自动模式下调用 |
| `NetHostSync.psm1` | hosts 变换模块(被 `update_hosts.ps1` 引用,走测试过的实现) |
| `config.json` | 运行配置(主机名列表、排除网卡等);个人参数,不进版本库 |
| `config.sample.json` | 配置模板(改 HostsTargets 后改名为 config.json 即可) |
| `NetHostSync.bat` | 双击启动菜单(已带 `-ExecutionPolicy Bypass`,无需改系统策略) |

> 四个脚本靠"脚本所在目录"互相定位,**必须放在同一个文件夹**里。

## 部署步骤

1. 把本目录整体复制到目标机**本地目录**(如 `E:\NetHostSync\`)。
   ⚠️ 计划任务以 **SYSTEM** 身份运行,**必须用本地路径**,不要用网络共享盘(SYSTEM 访问不到)。
2. (可选) 编辑 `config.json`:
   - `HostsTargets`:要同步的本地服务主机名(默认 `know.com` / `host.docker.internal` / `gateway.docker.internal`)
   - `ExcludeAdapters`:排除 VPN/虚拟网卡的正则
   - `UpdateHostsOnAuto`:自动触发时是否刷新 hosts
3. **以管理员身份**运行 `NetHostSync.bat` → 选菜单 **4** 注册计划任务。
   任务名 `NetworkConfigAutoSwitch`,包含:网络变化事件触发(秒级)+ 登录/启动 + 每 5 分钟兜底。
4. 验证:拔/插网线或切 Wi-Fi,查同目录 `network_switch.log` 是否出现「自动模式启动」及正确 IP。

## 排障

- **自动触发不生效**:在目标机跑 `diag_autotrigger.ps1`(需单独复制),拔线前后各一次,对比第 3 节事件。
- **注册失败**:确认以管理员运行;事件查看器 → 应用程序和服务日志 → Microsoft → Windows → NetworkProfile → Operational 已「启用」。
- **hosts 没更新**:跑 `update_hosts.ps1 -Diag`(只读)看选中的 IP 是否正确。
- **切换网络有最长 5 分钟延时**:正常现象——事件触发秒级,仅当事件未点火时靠 5 分钟兜底补。

## 卸载

`NetHostSync.bat` → 菜单「停用自动触发」(或运行 `network_config.ps1 -UninstallAuto`)即可卸载计划任务。
