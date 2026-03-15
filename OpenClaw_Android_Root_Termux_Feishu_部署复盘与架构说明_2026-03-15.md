# OpenClaw 在 Android（Redmi Note 8 Pro）上的 Root + Termux 部署复盘（Feishu 已验证）

> 文档目标：完整沉淀本次在 Android 设备上部署 OpenClaw 的技术过程、踩坑与最终可运行架构。  
> 文档范围：仅描述配置与实现方式；所有敏感信息（密钥、账号、Token、密码、设备标识）均已脱敏。

---

## 1. 项目背景与目标

### 1.1 目标

在一台 **Redmi Note 8 Pro（Android 11）** 上运行 OpenClaw，实现：

1. **开机自启** Gateway
2. **Feishu 通道可用**（已实测成功）
3. 出现异常（进程退出、网络抖动、代理污染）时可**自动自恢复**
4. 所有方案可被运维复盘，并可迁移到同类 Android + Root + Termux 环境

### 1.2 约束

- 官方安装体系优先面向桌面/服务器环境（见官方安装文档）
- Android 上缺少 systemd/launchd 这类标准服务管理器
- Root 场景下，`run-as` 与 `su` 的进程上下文/组权限差异会影响网络能力
- Termux 私有目录权限模型与 root 写入行为可能冲突

### 1.3 工具链

- **Codex（主要执行编排工具）**：用于全流程诊断、改造、验证、文档化
- **ADB（root shell）**：用于设备级脚本部署、权限修复、系统服务挂载
- **Termux 运行时**：OpenClaw CLI 与 Node 真正执行环境
- **Magisk service.d**：实现开机自启入口

---

## 2. 官方安装路径（基线）

参考官方：`https://docs.openclaw.ai/install`

官方安装页（2026-03-15 抓取）给出的主线是：

1. 安装 OpenClaw（installer / npm / pnpm / source 等）
2. 运行 onboarding（例如 `openclaw onboard --install-daemon`）
3. 通过 `openclaw doctor` / `openclaw status` / `openclaw dashboard` 验证
4. 可选使用 Docker / Podman / Nix / Ansible / Bun 等安装方式
5. 通过 `OPENCLAW_HOME` / `OPENCLAW_STATE_DIR` / `OPENCLAW_CONFIG_PATH` 调整路径策略

### 2.1 官方默认架构（抽象）

```text
CLI / UI Client
   -> Gateway (后台常驻)
      -> Channels / Agent / Tools / Models
```

在官方主线里，Gateway 常驻通常由“目标平台的标准后台机制”承担。

---

## 3. 本次 Android 实际问题时间线（完整复盘）

> 时间以本次会话日志为准（主要集中在 2026-03-14 ~ 2026-03-15）。

### 3.1 启动阶段配置失败

初始报错为配置校验失败，典型表现：

- `unknown channel id: feishu`
- `plugin not found: telegram / feishu / memory-core`

含义：配置引用了未加载或未安装的 channel/plugin，Gateway 在启动前即退出。

### 3.2 插件安装后出现“重复插件 ID”

安装 Feishu 扩展后出现：

- `duplicate plugin id detected`

根因：**bundled feishu** 与 `~/.openclaw/extensions/feishu` 同名并存。

处理：卸载/移除扩展侧重复项，保留唯一来源。

### 3.3 Feishu 运行时报错 `tenant_access_token` 解构失败

现象：

- `Cannot destructure property 'tenant_access_token' ... as it is undefined`

深挖日志后发现：

- `AssertionError [ERR_ASSERTION]: protocol mismatch`
- `actual: 'socks5h:' expected: 'http:'`

根因：Gateway 进程继承了 `all_proxy=socks5h://...`，而 axios/follow-redirects 路径期望 http/https 代理语义，导致 token 请求链路失败，后续触发空值解构。

### 3.4 Android Root 场景网络组权限问题

发现：从 Magisk/root 直接 `run-as com.termux` 拉起时，进程组可能缺失 `AID_INET(3003)`，导致 DNS/网络行为异常。

结论：必须以 Termux UID 启动，并显式补齐组权限。

### 3.5 `.bashrc` 权限问题

`openclaw doctor` 里出现 completion 安装失败：

- `EACCES: permission denied, open ~/.bashrc`

根因：`.bashrc` 所有权曾被 root 污染。

处理：恢复为 Termux 用户所有。

### 3.6 自愈需求升级

用户要求：不仅“能跑”，还要“重启自启 + 断网恢复 + 异常自动回连”。

最终引入了 Android 专用 watchdog（后文详述）。

---

## 4. 最终成功方案（当前生产可用架构）

### 4.1 最终架构图（Android 版）

```text
[Boot]
  -> Magisk service.d
      -> /data/adb/service.d/openclaw-gateway.sh
          -> su -g TERMUX_GID -G 3003 -G ALL_GID TERMUX_UID
              -> ~/.openclaw/gateway-service.android.sh
                  -> node ... openclaw gateway --port 18789

      -> /data/adb/service.d/openclaw-gateway-watchdog.sh
          -> su -g TERMUX_GID -G 3003 -G ALL_GID TERMUX_UID
              -> ~/.openclaw/gateway-watchdog.android.sh (daemon)
                  -> health/proxy/network probes
                  -> restart gateway when needed
```

### 4.2 关键二次开发点（Root + Android 定制）

#### A. 网关启动入口改造（service.d）

文件：`/data/adb/service.d/openclaw-gateway.sh`

核心改造：

- 不再依赖 root 直接跑业务进程
- 改为 `su` 切换到 Termux UID
- 显式补齐 `AID_INET(3003)` 与补充组

收益：Termux 语义一致、网络能力可预测。

#### B. Gateway Runner 增加代理污染防护

文件：`~/.openclaw/gateway-service.android.sh`

新增逻辑：启动前清理 SOCKS 代理环境变量（如 `all_proxy` / `ALL_PROXY` / `http_proxy` / `https_proxy` 中的 `socks*://`）。

收益：避免再次触发 `protocol mismatch`。

#### C. 新增 watchdog 守护（Android 专用）

文件：`~/.openclaw/gateway-watchdog.android.sh`

机制：

- 周期探活（`openclaw health --json`）
- 检测网关进程是否存在
- 检测进程环境是否存在 `socks` 代理污染
- 区分“网络离线”与“服务异常”
- 达到阈值后重启 gateway，并带冷却时间

收益：从“可启动”升级到“可持续运行”。

#### D. watchdog 自启入口

文件：`/data/adb/service.d/openclaw-gateway-watchdog.sh`

机制：与 gateway 启动入口一致，统一使用 `su + 组权限` 启动 Termux 侧守护进程。

---

## 5. 与官方架构的核心差异

| 维度 | 官方安装主线 | 本次 Android 落地 |
|---|---|---|
| 运行平台假设 | 桌面/服务器友好环境 | Android + Termux + Root |
| 后台管理 | `onboard --install-daemon` + 标准平台后台机制 | Magisk `service.d` + 自定义脚本 |
| 权限模型 | 用户态进程模型较稳定 | root/termux 混合，需显式 UID/GID/组控制 |
| 网络稳定性 | 通常不需要额外组修补 | 必须显式补 `AID_INET(3003)` |
| 代理处理 | 通常依赖环境一致性 | 增加 SOCKS 代理污染清理 |
| 自恢复能力 | 依赖平台服务管理与 OpenClaw 自身机制 | 额外引入 Android watchdog 主动修复 |
| Android 支持方式 | 官方平台文档覆盖“Android app/node”连接场景 | 本项目重点是“Android 机内本地部署 Gateway” |

结论：

- 我们不是偏离 OpenClaw 协议层，而是补齐了 **Android Root 环境下缺失的“服务管理与进程卫生层”**。

---

## 6. 详细操作分层：哪些在 ADB，哪些在 Termux

### 6.1 必须在 ADB/root 侧做的事情

1. 向 `/data/adb/service.d/` 写入开机脚本
2. 修正 root 污染的文件所有权/权限（如 `.bashrc`、watchdog pid/log）
3. 设备级网络/进程级诊断（`/proc/<pid>/environ`、`ss`、`ps`）
4. 开机流程模拟与验证（直接触发 service.d 脚本）

### 6.2 必须在 Termux 用户上下文做的事情

1. 运行 OpenClaw CLI（`doctor/status/health/channels/config`）
2. 管理配置文件（`~/.openclaw/openclaw.json`）
3. 通道探测（Feishu probe）
4. pairing 审批（示例：`openclaw pairing approve feishu <CODE>`）

### 6.3 典型混合调用模式

- root 脚本中通过 `su -g <gid> -G 3003 -G <all_gid> <uid> -c "..."` 进入 Termux 语境运行命令。

---

## 7. 配置清单（脱敏模板）

> 以下只给出结构，不包含任何真实敏感值。

### 7.1 Gateway 配置（`openclaw.json`）

```json
{
  "gateway": {
    "port": 18789,
    "mode": "local",
    "bind": "lan",
    "auth": {
      "mode": "password",
      "password": "<REDACTED>"
    },
    "controlUi": {
      "allowedOrigins": [
        "http://localhost:18789",
        "http://127.0.0.1:18789"
      ]
    }
  }
}
```

要点：

- `bind=lan` 便于局域网访问，但需更强认证与隔离
- `allowedOrigins` 必须与控制端一致
- 密码/token 必须单独保密管理

### 7.2 Feishu 通道配置（模板）

```json
{
  "channels": {
    "feishu": {
      "enabled": true,
      "appId": "<REDACTED>",
      "appSecret": "<REDACTED>",
      "domain": "feishu",
      "connectionMode": "websocket",
      "groupPolicy": "open"
    }
  },
  "plugins": {
    "entries": {
      "feishu": {
        "enabled": true
      }
    }
  }
}
```

要点：

- 若 `groupPolicy=allowlist`，必须配置 `groupAllowFrom/allowFrom`
- 插件来源保持唯一，避免 duplicate plugin id
- 配对成功后用 `channels status --probe --json` 验证 `probe.ok=true`

### 7.3 模型配置（本次调整）

本次统一策略：

- 全部 `contextWindow = 200000`
- 全部 `maxTokens = 8192`

要点：

- `contextWindow` 控制输入+输出总预算
- `maxTokens` 控制单次最大输出预算
- 每次修改后执行 `openclaw config validate`

### 7.4 环境变量与路径策略（官方建议）

可按需控制：

- `OPENCLAW_HOME`
- `OPENCLAW_STATE_DIR`
- `OPENCLAW_CONFIG_PATH`

建议：Android/Termux 里统一固定路径，降低脚本复杂度与迁移风险。

---

## 8. 关键脚本说明（现网版本）

### 8.1 `openclaw-gateway.sh`（service.d）

职责：

- 解析 Termux UID/GID
- 使用 `su` 切用户并补组
- 调起 `gateway-service.android.sh`

### 8.2 `gateway-service.android.sh`

职责：

- 设置 Termux 运行环境变量（`HOME/PREFIX/PATH/TMPDIR`）
- 启停 gateway 进程并维护 PID
- 启动前清理 SOCKS 代理污染变量

### 8.3 `openclaw-gateway-watchdog.sh`（service.d）

职责：

- 开机拉起 watchdog
- 同样使用 `su + AID_INET` 模式，避免权限漂移

### 8.4 `gateway-watchdog.android.sh`

职责：

- 单实例守护
- 45 秒周期探活
- 失败阈值 2 次、重启冷却 120 秒
- 网络离线时不盲目重启，网络恢复后自动修复

---

## 9. 运维观测与验收标准

### 9.1 基础状态检查

```bash
openclaw gateway status --json
openclaw health --json --timeout 7000
openclaw channels status --probe --json
```

验收点：

- `gateway.rpc.ok = true`
- `channels.feishu.probe.ok = true`
- 无 `protocol mismatch` / `tenant_access_token` 异常

### 9.2 守护检查

```bash
/system/bin/sh ~/.openclaw/gateway-watchdog.android.sh status
tail -f ~/.openclaw/gateway-watchdog.android.log
```

验收点：

- watchdog 进程常驻
- 能看到异常恢复日志（如 process missing / restart）

### 9.3 断网恢复演练

演练方法（摘要）：

1. 临时断网
2. 杀掉 gateway 进程
3. 恢复网络
4. 观察 watchdog 自动拉起与健康恢复

本次实测：通过。

---

## 10. 安全与稳定性建议

1. `bind=lan` 时务必强化 `auth`（强密码或 token）
2. 长期建议将远程接入切到隧道模型（Tailscale/SSH Tunnel）
3. 防止 root 写入破坏 Termux 所有权
4. 每次升级 OpenClaw 后检查“生成脚本是否覆盖自定义改造”
5. 对自定义脚本建立版本管理（git 或定期备份）

---

## 11. 本次“最终采用方式”总结

最终成功方案不是单点修复，而是四层联动：

1. **进程权限层**：Termux UID + AID_INET 组
2. **网络环境层**：启动前清理 SOCKS 代理污染
3. **服务编排层**：Magisk service.d 自启 gateway + watchdog
4. **运行健康层**：watchdog 主动探活与自动恢复

这套方案让 OpenClaw 在 Android Root 场景下达到“可启动、可连接、可恢复、可运维”的状态，Feishu 已验证成功。

---

## 12. 附录：官方文档对照

- 安装总览：`https://docs.openclaw.ai/install`
- 架构概念：`https://docs.openclaw.ai/concepts/architecture`
- Android 平台：`https://docs.openclaw.ai/platforms/android`
- Gateway 后台与运维相关（导航入口）：`https://docs.openclaw.ai/gateway`

---

## 13. 变更记录（本次会话）

- 2026-03-14：完成 Gateway 网络组权限修复、代理污染修复、Feishu可用性恢复
- 2026-03-14：完成 watchdog 设计与接入，完成断网恢复演练
- 2026-03-15：完成模型配置统一（`contextWindow=200000`，`maxTokens=8192`）
- 2026-03-15：输出本技术复盘文档（本文件）

