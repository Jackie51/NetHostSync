# 故障排查 / 踩坑记录

本工具在开发过程中踩过不少 Windows 计划任务与网络探测的坑，记录在此，便于自检与二次开发。

## 1. 自动触发完全不执行（hosts 从不更新）

- **现象**：网络切了，hosts 没变，`network_switch.log` 里也没有「自动模式启动」。
- **原因**：事件通道 `Microsoft-Windows-NetworkProfile/Operational` 在部分系统**默认禁用**，不记录任何事件，事件触发器永远不会点火，自动任务形同虚设。
- **解决**：注册时已用 `wevtutil sl "Microsoft-Windows-NetworkProfile/Operational" /e:true` 显式启用；若仍不点火，手动在「事件查看器 → 应用程序和服务日志 → Microsoft → Windows → NetworkProfile → Operational」右键启用。也可在 `taskschd.msc` 看任务「上次运行时间 / 结果」确认是否真的跑过。

## 2. 切到热点没更新，插回有线却更新了（或反之）

- **现象**：只覆盖部分切换方向。
- **原因**：早期版本只监听了「连接」事件 10000，没监听「断开」10001，导致某些切换方向不触发。
- **解决**：XPath 已改为 `EventID=10000 or EventID=10001`，插拔网线 / 切 Wi-Fi / 切手机热点全覆盖。

## 3. 注册计划任务时各种报错

- **现象**：`Invalid argument/option`、`(17,35):LogonType:ServiceAccount` 越界、`Exception setting 'Subscription'` 等。
- **原因**：Windows 计划任务事件触发器的注册有多个坑：
  1. `schtasks /Create /TR` 中含空格的脚本路径，引号被 PowerShell 的 `&` / `Start-Process` 破坏；
  2. TaskScheduler COM 的触发器对象在 PowerShell 中拿不到 `Subscription` 属性；
  3. 手搓 XML 时 `Principal` 元素顺序、`LogonType` 取值校验严格（报 ServiceAccount 越界）；
  4. `ProcessStartInfo.Arguments` 双层 `CommandLineToArgvW` 转义破坏内部 `\"`，导致路径被拆散。
- **解决**：最终方案是把完整 `schtasks /Create` 命令写进一个临时 `.cmd`（cmd 原生 `\"` 转义），再由脚本**无参启动**该 `.cmd`，所有引号转义留在 `.cmd` 内部由 cmd 正确解析，彻底绕开上述四类问题。注册成功后还会读取任务 XML，关闭「仅交流电源运行」限制。

## 4. 自动触发时 hosts 不更新，但手动双击 .bat 却正常

- **现象**：手动运行 `update_hosts.ps1` 成功；自动触发（计划任务 / SYSTEM）却静默失败，hosts 没动。
- **原因**：脚本原「UAC 自提权」逻辑只判断 `IsInRole(Administrator)`，而计划任务以 SYSTEM 运行时该判断**常为 `$false`**，于是执行 `Start-Process -Verb RunAs` 请求交互式 UAC 提权——SYSTEM 没有交互桌面、UAC 无法 consent，提权**静默失败、原进程直接退出**，hosts 因此没更新。
- **解决**：两个脚本都改为「**SYSTEM 或已是管理员就直接执行，绝不走 UAC**」；仅「非管理员且非 SYSTEM 的交互会话」才尝试 UAC 提权。

## 5. 切换瞬间 hosts 写成了旧 IP / 没更新

- **现象**：刚切到手机热点，hosts 还是旧的有线静态 IP，或日志显示未检测到可用 IPv4。
- **原因**：IP 探测依赖聚合的网关信息，切换瞬间旧网卡可能还带残留网关、新网卡尚未拿到地址，导致误填旧地址或返回空而跳过。
- **解决**：重写探测逻辑为只认「当前已连接（Up & Connected）」的网卡，排除 169.254 链路本地，按「有默认网关 > 有线 > 路由度量小」取最优；并在切换后重试最多 6 次、每次间隔 3 秒，规避 DHCP 尚未完成。

## 6. 目标域名只出现在注释里，却没生成生效映射

- **现象**：`hosts` 里某项只在 `#` 注释行中出现，运行后仍是注释状态，没有激活行。
- **原因**：旧逻辑把「注释行中出现目标主机名」也算作已存在，从而不追加激活行。
- **解决**：改为只认**激活行**为已存在；注释中的目标名不计入，缺失项照常追加，确保 hosts 始终含指向当前 IP 的生效映射。

## 7. 笔记本用电池 / 手机热点时任务不跑

- **现象**：插电源时正常，拔电源用热点就不触发。
- **原因**：计划任务默认 `DisallowStartIfOnBatteries=true` + `StopIfGoingOnBatteries=true`，电池供电时被抑制。
- **解决**：注册成功后读取任务 XML，将 `DisallowStartIfOnBatteries=false`、`StopIfGoingOnBatteries=false`、`StartWhenAvailable=true` 写回。属于健壮性改进，与第 4 条的 SYSTEM 提权真因相互独立。

## 8. VPN 断线 / 被误改

- **现象**：连 VPN 后 hosts 被指向 VPN 隧道 IP，或 VPN 异常。
- **原因**：某些 VPN 以虚拟以太网卡（DHCP 方式）呈现，会骗过「仅物理网卡」过滤。
- **解决**：`ExcludeAdapters` 正则 + Tunnel 类型双重排除，VPN / TAP / OpenVPN / WireGuard / Cisco / AnyConnect 等一律不纳入 IP 管理。如有特殊名称未被覆盖，在 `config.json` 加入关键字即可。

## 日志排障口诀

1. 查 `network_switch.log` 是否有「自动模式启动」→ 判断任务是否点火；
2. 查 `update_hosts.log` 是否有「检测到 IPv4：...」与「hosts 更新完成」→ 判断 IP 探测与写入；
3. `taskschd.msc` 看 `NetworkConfigAutoSwitch` 的「上次运行时间 / 上次运行结果」。
