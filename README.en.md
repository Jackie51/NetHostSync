# NetHostSync — Auto-sync hosts on network change

A lightweight, zero-dependency (pure PowerShell) Windows utility: it listens for network changes (plug/unplug cable, switch Wi-Fi, tethering hotspot) and automatically points the specified service domains in `hosts` to the **current active IPv4**. Built for developers who use Docker Desktop or local services and frequently switch between multiple networks.

## What it does

- On any network connection change, automatically updates the specified `hosts` entries to point at the IPv4 you are currently using.
- When wired / wireless / mobile hotspot are connected **at the same time**, it prefers the wired adapter's IPv4 (if present).
- Only modifies **non-commented (active)** lines in `hosts`; comments and everything else are left untouched. Missing target domains are appended automatically.
- Optional network configuration: assign a static IP to the wired adapter and keep wireless on DHCP; switching does not interrupt Windows' own DHCP renewal.
- Can be registered as a silent, fully background scheduled task (running as SYSTEM).

## Use cases

- Developers using Docker Desktop / local services who frequently switch between wired, home Wi-Fi, and mobile hotspot.
- Services reached via custom domains (e.g. `know.com`) or `host.docker.internal` break as soon as the IP changes.
- You want `hosts` to follow the network automatically instead of editing it by hand.

## Requirements

- Windows 10 / 11
- PowerShell 5.1 or later (ships with Windows)
- Modifying `hosts` and registering the scheduled task require administrator privileges (the auto-trigger runs as SYSTEM, no interactive elevation needed)

## Install

Put these files in the **same folder** (no dependencies to install):

- `network_config.ps1` — network configuration + auto-trigger main script
- `update_hosts.ps1` — hosts sync script
- `NetHostSync.psm1` — unit-testable pure transform logic (imported by `update_hosts.ps1`)
- `config.json` — configuration (auto-generated on first run; see [`config.sample.json`](./config.sample.json) for the field meanings)
- `网络配置.bat` / `更新hosts.bat` — optional launchers

> Curious how your `hosts` will be transformed? See the annotated [`hosts.sample`](./hosts.sample).

## Configuration (config.json)

All tunable parameters live in `config.json`; no need to edit scripts. Fields:

- `HostsTargets`: array of `hosts` domain names to sync with the network (3 defaults).
- `DefaultIP` / `DefaultMask` / `DefaultGateway` / `DefaultDNS1` / `DefaultDNS2`: default static values for the wired adapter.
- `WiredMetric` / `WirelessMetric`: interface priority (lower = preferred; wired 10 < wireless 20 ensures wired wins when both are connected).
- `ExcludeAdapters`: regex; adapters whose name matches (VPN / virtual adapters) are excluded so tunnel IPs are never touched.
- `UpdateHostsOnAuto`: whether to also refresh `hosts` during auto-trigger (true / false).
- `UpdateHostsScript`: hosts script file name (usually left as-is).

Tip: the current `ExcludeAdapters` uses literal-space matching for "WAN Miniport" / "Check Point". For looser matching (any whitespace), use `\s*` instead of a space in `ExcludeAdapters` (note: each backslash must be doubled in JSON).

## Usage

### Interactive menu

Double-click `网络配置.bat` (or right-click `network_config.ps1` → Run as administrator). Menu:

- `1` Auto-switch (wired → default static, wireless → DHCP, and refresh hosts)
- `2` Set wired static
- `3` Set wireless DHCP
- `4` Enable auto-trigger on network change (register scheduled task)
- `5` Disable auto-trigger
- `6` Restore previous adapter config (backup.json)
- `7` Diagnostics (read-only)
- `8` Exit

### Command line

- Auto-switch (called by the scheduled task): `powershell -File network_config.ps1 -Auto`
- Register auto-trigger: `network_config.ps1 -InstallAuto`
- Uninstall auto-trigger: `network_config.ps1 -UninstallAuto`
- Read-only diagnostics: `network_config.ps1 -Diag`

### hosts sync

- Manual refresh: right-click `更新hosts.bat` (or directly `update_hosts.ps1`) → Run as administrator
- Read-only diagnostics (no admin needed): `powershell -File update_hosts.ps1 -Diag`
- Temporary entries (not written to config): `powershell -File update_hosts.ps1 -HostEntries a.local,b.local`

## Auto-trigger (scheduled task)

- After registration, the system watches the `Microsoft-Windows-NetworkProfile/Operational` event log (network connect 10000 and disconnect 10001); any connectivity change fires it.
- Runs `Network Auto-Switch -Auto` as SYSTEM, which then calls `update_hosts.ps1` to refresh hosts.
- Registration automatically enables the (often disabled by default) event channel, otherwise the trigger would never fire.
- Uninstall: menu `5` or `-UninstallAuto`. This cleans up the named task and any leftover tasks pointing to this folder's scripts — no duplicate accumulation.

## ⚠️ Security notes (please read)

This tool does modify your system, but the scope is explicit and limited:

- **[Modifies]** `C:\Windows\System32\drivers\etc\hosts`: rewrites the IP of the `HostsTargets` domains to the current active IPv4 (only non-commented lines; comments/others untouched). **Written by direct overwrite, no backup file is created.**
- **[Modifies]** Scheduled task: registers/unregisters a system task named `NetworkConfigAutoSwitch` (`/RU SYSTEM`).
- **[Optionally modifies]** Network adapters: only during "auto-switch / menu 1", assigns a static IP to the connected wired adapter and restores DHCP on a leftover-static wireless adapter (idempotent, no repeated pushes, does not interrupt DHCP renewal).
- **[Does not modify]** No drivers installed, no system registry changed, no system files other than `hosts` touched; `hosts` changes only happen when you run the script or the auto-trigger fires.
- **[Permissions]** Modifying `hosts` and registering the task requires admin / SYSTEM. Interactive mode auto-requests UAC elevation; the auto-trigger runs as SYSTEM (no UAC prompt, executes directly).
- **[Rollback]** `hosts` has no backup. To revert: manually edit `hosts` to set those IPs back, or first `-Diag` to see current values. Adapter IP can be restored via menu `6` (`backup.json`, unrelated to the rest of this tool and left intact).
- Before registering, any leftover same-name / dirty tasks from earlier failed attempts are cleaned up automatically.

## Logs

- `network_switch.log`: network switching and auto-trigger records.
- `update_hosts.log`: details of every hosts refresh (detected IP, updated / appended / skipped).
- Attach both logs when troubleshooting.

## FAQ

- **Auto-trigger not firing?** First check `network_switch.log` for "自动模式启动" (auto mode started) to see if the task fired; then check `update_hosts.log` for IP detection / write results. See `TROUBLESHOOTING.md`.
- **Wireless IP changes every time?** No worry — the script probes the current address in real time, always matching the live network.
- **Will it affect VPN?** No. VPN / virtual adapters are excluded by `ExcludeAdapters` and never touched.

## Troubleshooting

See `TROUBLESHOOTING.md`.

## Development & Tests

This repo ships with offline, dependency-free tests for the core `hosts` transform logic (the part most likely to break).

- Pure logic lives in `NetHostSync.psm1` (`Update-HostsLines`), with no file/network side effects.
- **With Pester** (recommended for local dev):
  ```powershell
  Install-Module Pester -Force -Scope CurrentUser
  Invoke-Pester -Path tests/NetHostSync.Tests.ps1
  ```
- **Without Pester** (or in restricted environments), run the equivalent assertions:
  ```powershell
  powershell -File tests/Verify.ps1
  ```
  Exit code 0 = all pass.
- Static analysis: `Invoke-ScriptAnalyzer -Path . -Recurse -Settings PSScriptAnalyzerSettings.psd1`
- CI: GitHub Actions (`.github/workflows/ci.yml`) runs PSScriptAnalyzer (Error/Warning only) and Pester on `windows-latest` on every push/PR.

## License

MIT — see `LICENSE`.
