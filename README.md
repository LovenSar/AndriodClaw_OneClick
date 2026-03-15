# Android OpenClaw One-Click

一键完成 **Android 设备兼容性检查 + OpenClaw Root 化部署** 的脚本。

脚本文件：`android_openclaw_oneclick.sh`

## 功能

- 自动选择/指定 ADB 设备
- 检查设备 root、Magisk、Termux、Node、OpenClaw 运行条件
- 将 OpenClaw 网关与 watchdog 以 root 方式部署到设备
- 可输出 JSON 报告（stdout 或文件）用于自动化验收

## 前置条件

### 主机侧（运行脚本的电脑）

- `adb`
- `awk`
- `mktemp`

### 设备侧（Android）

- 已连接并可被 `adb devices` 识别
- 已 root，且 `su` 可用
- 已安装 Magisk，且可写：
  - `/data/adb`
  - `/data/adb/service.d`
  - `/data/adb/modules`
- 已安装 Termux（稳定版/夜版/社区包名均可），并满足：
  - 存在 Node：`.../usr/bin/node`
  - 全局安装 OpenClaw：`.../usr/lib/node_modules/openclaw/openclaw.mjs`
  - 已完成 gateway install，存在：
    - `~/.openclaw/gateway-service.android.sh`
    - `~/.openclaw/gateway-watchdog.android.sh`

## 快速开始

### 1) 仅做检查（不改设备）

```bash
./android_openclaw_oneclick.sh --check
```

### 2) 一键部署（默认模式）

```bash
./android_openclaw_oneclick.sh --deploy
# 或直接：
./android_openclaw_oneclick.sh
```

### 3) 多设备时指定序列号

```bash
./android_openclaw_oneclick.sh --serial <adb-serial>
# 或
./android_openclaw_oneclick.sh <adb-serial>
```

## 参数说明

- `--deploy`：执行检查并部署（默认）
- `--check` / `--check-only`：仅检查，不改动
- `-s, --serial <id>`：指定设备序列号
- `--report-json`：将结果 JSON 输出到 stdout
- `--report-json-file <path>`：将结果 JSON 写入文件
- `-h, --help`：查看帮助

## JSON 报告示例

```bash
./android_openclaw_oneclick.sh --check --report-json-file report.json
cat report.json
```

报告包含：

- `status`（`ok`/`error`）
- `device`（品牌、型号、Android、SDK、ABI、SELinux、内核）
- `compatibility.status` 与告警列表
- `deploy`（状态、gateway PID/UID、root 命令状态）
- 关键路径与 Magisk 版本

## 脚本会改动的设备路径

部署模式下会写入/覆盖以下路径（并自动备份部分旧文件）：

- `/data/adb/openclaw/openclaw-root-entry.sh`
- `/data/adb/service.d/openclaw-gateway.sh`
- `/data/adb/service.d/openclaw-gateway-watchdog.sh`
- `/data/adb/modules/openclaw_cmd/module.prop`
- `/data/adb/modules/openclaw_cmd/system/bin/openclaw`
- `Termux/usr/bin/openclaw`（会备份为 `*.bak.oneclick.<timestamp>`）

## 部署后验证

```bash
adb shell su -c "pidof openclaw-gateway"
adb shell su -c "awk '/^Uid:/{print \$2}' /proc/\$(pidof openclaw-gateway | awk '{print \$1}')/status"
adb shell su -c "/system/bin/sh /data/adb/openclaw/openclaw-root-entry.sh --version"
```

预期：

- `openclaw-gateway` 有 PID
- UID 为 `0`
- 版本命令可执行

## 常见问题

- `ADB 设备未连接`：先执行 `adb devices -l`，确认设备在线并已授权。
- `检测到多个设备`：使用 `--serial` 指定目标设备。
- `设备未获得 root`：确认 `su` 已授权给 shell。
- `未检测到 Magisk` 或缺少 `/data/adb/service.d`：检查 Magisk 安装与工作状态。
- `未检测到 Termux 根路径`：确认已安装 Termux，并具备 Node。
- `未找到 ...openclaw.mjs`：在 Termux 中完成 OpenClaw 全局安装。
- `root shell 暂无 /system/bin/openclaw`：通常重启一次手机后可用（Magisk 挂载生效）。

## 注意事项

- 本脚本依赖 root 与 Magisk，风险自担。
- 建议先执行 `--check`，确认通过后再部署。
- 若设备无法写入 `/data/local/tmp`，脚本会自动回退到 `/sdcard` 路径进行临时推送。
