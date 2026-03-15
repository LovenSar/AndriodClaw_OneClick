#!/usr/bin/env bash
set -euo pipefail

MODE="deploy"
SERIAL="${ANDROID_SERIAL:-}"
PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
REPORT_JSON=0
REPORT_JSON_FILE=""

TERMUX_BASE=""
TERMUX_PREFIX=""
TERMUX_HOME=""
NODE_BIN=""
OPENCLAW_MAIN=""
GATEWAY_RUNNER=""
WATCHDOG_RUNNER=""
TERMUX_UID=""
TERMUX_GID=""
PUSH_BASE=""
TMP_LOCAL_CLEANUP=""

ADB=(adb)
WARNINGS=()
ERROR_MESSAGE=""

DEVICE_BRAND=""
DEVICE_MODEL=""
DEVICE_ANDROID=""
DEVICE_SDK=""
DEVICE_ABI=""
DEVICE_SELINUX=""
DEVICE_KERNEL_GETPROP=""
DEVICE_KERNEL_UNAME=""
MAGISK_VERSION=""

CHECK_STATUS="pending"
DEPLOY_STATUS="not_run"
DEPLOY_GATEWAY_PID=""
DEPLOY_GATEWAY_UID=""
ROOT_CMD_STATE="unknown"

trap 'if [[ -n "${TMP_LOCAL_CLEANUP:-}" ]]; then rm -rf "${TMP_LOCAL_CLEANUP}"; fi' EXIT

usage() {
  cat <<'EOF'
Usage:
  android_openclaw_oneclick.sh [--deploy|--check] [--serial <adb-serial>] [--report-json]
  android_openclaw_oneclick.sh [--deploy|--check] [--serial <adb-serial>] [--report-json-file <path>]
  android_openclaw_oneclick.sh [<adb-serial>]

Options:
  --deploy              执行兼容性检查 + 一键部署（默认）
  --check, --check-only 仅做兼容性检查，不改动设备
  -s, --serial          指定设备序列号（多设备时必须）
  --report-json         输出 JSON 报告到 stdout（可用于批量验收）
  --report-json-file    输出 JSON 报告到指定文件
  -h, --help            显示帮助
EOF
}

log() {
  printf '[openclaw-oneclick] %s\n' "$*"
}

warn() {
  WARNINGS+=("$*")
  printf '[openclaw-oneclick] WARN: %s\n' "$*"
}

json_escape() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "${value}"
}

emit_json_report() {
  local ts status warnings_json warning escaped_error json_out

  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  status="ok"
  [[ -n "${ERROR_MESSAGE}" ]] && status="error"

  warnings_json=""
  if (( ${#WARNINGS[@]:-0} > 0 )); then
    for warning in "${WARNINGS[@]}"; do
      escaped_error="$(json_escape "${warning}")"
      if [[ -n "${warnings_json}" ]]; then
        warnings_json="${warnings_json},"
      fi
      warnings_json="${warnings_json}\"${escaped_error}\""
    done
  fi

  json_out=$(cat <<EOF
{
  "timestamp": "$(json_escape "${ts}")",
  "mode": "$(json_escape "${MODE}")",
  "status": "$(json_escape "${status}")",
  "error": "$(json_escape "${ERROR_MESSAGE}")",
  "device": {
    "serial": "$(json_escape "${SERIAL}")",
    "brand": "$(json_escape "${DEVICE_BRAND}")",
    "model": "$(json_escape "${DEVICE_MODEL}")",
    "android": "$(json_escape "${DEVICE_ANDROID}")",
    "sdk": "$(json_escape "${DEVICE_SDK}")",
    "abi": "$(json_escape "${DEVICE_ABI}")",
    "selinux": "$(json_escape "${DEVICE_SELINUX}")",
    "kernelGetprop": "$(json_escape "${DEVICE_KERNEL_GETPROP}")",
    "kernelUname": "$(json_escape "${DEVICE_KERNEL_UNAME}")"
  },
  "compatibility": {
    "status": "$(json_escape "${CHECK_STATUS}")",
    "warnings": [${warnings_json}]
  },
  "deploy": {
    "status": "$(json_escape "${DEPLOY_STATUS}")",
    "gatewayPid": "$(json_escape "${DEPLOY_GATEWAY_PID}")",
    "gatewayUid": "$(json_escape "${DEPLOY_GATEWAY_UID}")",
    "rootCommandState": "$(json_escape "${ROOT_CMD_STATE}")"
  },
  "paths": {
    "termuxBase": "$(json_escape "${TERMUX_BASE}")",
    "termuxPrefix": "$(json_escape "${TERMUX_PREFIX}")",
    "termuxHome": "$(json_escape "${TERMUX_HOME}")",
    "gatewayRunner": "$(json_escape "${GATEWAY_RUNNER}")",
    "watchdogRunner": "$(json_escape "${WATCHDOG_RUNNER}")",
    "pushBase": "$(json_escape "${PUSH_BASE}")"
  },
  "versions": {
    "magisk": "$(json_escape "${MAGISK_VERSION}")"
  }
}
EOF
)

  if [[ -n "${REPORT_JSON_FILE}" ]]; then
    if ! printf '%s\n' "${json_out}" > "${REPORT_JSON_FILE}"; then
      printf '[openclaw-oneclick] WARN: 写入 JSON 报告失败: %s\n' "${REPORT_JSON_FILE}" >&2
      printf '%s\n' "${json_out}"
      return
    fi
    log "JSON 报告已写入: ${REPORT_JSON_FILE}"
    return
  fi

  printf '%s\n' "${json_out}"
}

die() {
  ERROR_MESSAGE="$*"
  CHECK_STATUS="${CHECK_STATUS:-failed}"
  if [[ "${DEPLOY_STATUS}" == "running" ]]; then
    DEPLOY_STATUS="failed"
  elif [[ "${DEPLOY_STATUS}" == "not_run" && "${MODE}" == "deploy" ]]; then
    DEPLOY_STATUS="failed"
  fi
  printf '[openclaw-oneclick] ERROR: %s\n' "${ERROR_MESSAGE}" >&2
  if [[ "${REPORT_JSON}" == "1" ]]; then
    emit_json_report
  fi
  exit 1
}

run_adb() {
  "${ADB[@]}" "$@"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

trim_cr() {
  tr -d '\r'
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --deploy)
        MODE="deploy"
        shift
        ;;
      --check|--check-only)
        MODE="check"
        shift
        ;;
      -s|--serial)
        [[ $# -ge 2 ]] || die "--serial 需要参数"
        SERIAL="$2"
        shift 2
        ;;
      --report-json)
        REPORT_JSON=1
        shift
        ;;
      --report-json-file)
        [[ $# -ge 2 ]] || die "--report-json-file 需要参数"
        REPORT_JSON=1
        REPORT_JSON_FILE="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        if [[ -z "${SERIAL}" ]]; then
          SERIAL="$1"
          shift
        else
          die "unknown argument: $1"
        fi
        ;;
    esac
  done
}

select_device() {
  local devices=()

  if [[ -n "${SERIAL}" ]]; then
    ADB=(adb -s "${SERIAL}")
    if ! run_adb get-state >/dev/null 2>&1; then
      die "设备 ${SERIAL} 不可用"
    fi
    return
  fi

  while IFS= read -r line; do
    [[ -n "${line}" ]] && devices+=("${line}")
  done < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
  if (( ${#devices[@]} == 0 )); then
    die "ADB 设备未连接。先执行: adb devices -l"
  fi
  if (( ${#devices[@]} > 1 )); then
    die "检测到多个设备，请使用 --serial 指定设备"
  fi
  SERIAL="${devices[0]}"
  ADB=(adb -s "${SERIAL}")
}

run_root() {
  local cmd="$1"
  local esc
  esc="$(printf "%s" "$cmd" | sed "s/'/'\\\\''/g")"
  run_adb shell "su -c '$esc'"
}

detect_termux_base() {
  TERMUX_BASE="$(run_root "for b in /data/data/com.termux/files /data/data/com.termux.nightly/files /data/data/com.termux.github/files /data/data/*termux*/files; do [ -d \"\$b\" ] || continue; [ -x \"\$b/usr/bin/node\" ] || continue; [ -d \"\$b/home\" ] || continue; echo \"\$b\"; break; done" 2>/dev/null | trim_cr | head -n1)"
  [[ -n "${TERMUX_BASE}" ]] || die "未检测到 Termux 根路径（需先安装 Termux + Node）"
}

detect_push_base() {
  local candidate

  for candidate in /data/local/tmp /sdcard/Download /sdcard; do
    if run_adb shell "sh -c 'mkdir -p \"${candidate}\" >/dev/null 2>&1 && touch \"${candidate}/.openclaw_push_test\" >/dev/null 2>&1 && rm -f \"${candidate}/.openclaw_push_test\"'" >/dev/null 2>&1; then
      PUSH_BASE="${candidate}"
      break
    fi
  done

  [[ -n "${PUSH_BASE}" ]] || die "ADB 无可写临时目录（/data/local/tmp 或 /sdcard）"
}

compatibility_check() {
  local root_id

  need_cmd adb
  need_cmd awk
  need_cmd mktemp

  select_device
  log "目标设备: ${SERIAL}"

  DEVICE_MODEL="$(run_adb shell getprop ro.product.model | trim_cr)"
  DEVICE_BRAND="$(run_adb shell getprop ro.product.brand | trim_cr)"
  DEVICE_ANDROID="$(run_adb shell getprop ro.build.version.release | trim_cr)"
  DEVICE_SDK="$(run_adb shell getprop ro.build.version.sdk | trim_cr)"
  DEVICE_ABI="$(run_adb shell getprop ro.product.cpu.abi | trim_cr)"
  DEVICE_SELINUX="$(run_adb shell getenforce 2>/dev/null | trim_cr || true)"
  DEVICE_KERNEL_GETPROP="$(run_adb shell getprop ro.kernel.version | trim_cr)"
  DEVICE_KERNEL_UNAME="$(run_adb shell uname -r | trim_cr)"
  log "设备信息: ${DEVICE_BRAND} ${DEVICE_MODEL}, Android ${DEVICE_ANDROID} (SDK ${DEVICE_SDK}), ABI ${DEVICE_ABI}"
  [[ -n "${DEVICE_SELINUX}" ]] && log "SELinux: ${DEVICE_SELINUX}"
  [[ -n "${DEVICE_KERNEL_GETPROP}" ]] && log "Kernel(getprop): ${DEVICE_KERNEL_GETPROP}"
  [[ -n "${DEVICE_KERNEL_UNAME}" ]] && log "Kernel(uname): ${DEVICE_KERNEL_UNAME}"

  root_id="$(run_adb shell 'su -c "id"' 2>/dev/null | trim_cr || true)"
  [[ "${root_id}" == uid=0* ]] || die "设备未获得 root（su 不可用或未授权）"
  log "Root 检查: OK (${root_id})"

  if ! run_root "command -v magisk >/dev/null 2>&1"; then
    die "未检测到 Magisk；此脚本依赖 /data/adb/service.d 和 Magisk 模块挂载"
  fi
  MAGISK_VERSION="$(run_root "magisk -v 2>/dev/null || true" | trim_cr)"
  [[ -n "${MAGISK_VERSION}" ]] && log "Magisk: ${MAGISK_VERSION}"

  run_root "test -d /data/adb" >/dev/null || die "缺少 /data/adb"
  run_root "test -d /data/adb/service.d" >/dev/null || die "缺少 /data/adb/service.d（Magisk service.d 不可用）"
  run_root "test -d /data/adb/modules" >/dev/null || die "缺少 /data/adb/modules"
  run_root "touch /data/adb/.openclaw_write_test && rm -f /data/adb/.openclaw_write_test" >/dev/null || die "/data/adb 不可写"

  for c in sh cp chmod chown awk sed pidof nohup setsid; do
    run_root "command -v ${c} >/dev/null 2>&1" >/dev/null || die "系统缺少命令: ${c}"
  done

  detect_termux_base
  TERMUX_PREFIX="${TERMUX_BASE}/usr"
  TERMUX_HOME="${TERMUX_BASE}/home"
  NODE_BIN="${TERMUX_PREFIX}/bin/node"
  OPENCLAW_MAIN="${TERMUX_PREFIX}/lib/node_modules/openclaw/openclaw.mjs"
  GATEWAY_RUNNER="${TERMUX_HOME}/.openclaw/gateway-service.android.sh"
  WATCHDOG_RUNNER="${TERMUX_HOME}/.openclaw/gateway-watchdog.android.sh"

  run_root "test -x '${NODE_BIN}'" >/dev/null || die "未找到 ${NODE_BIN}"
  run_root "test -f '${OPENCLAW_MAIN}'" >/dev/null || die "未找到 ${OPENCLAW_MAIN}（需 npm 全局安装 openclaw）"
  run_root "test -x '${GATEWAY_RUNNER}'" >/dev/null || die "未找到 ${GATEWAY_RUNNER}（需先完成 openclaw gateway install）"
  run_root "test -x '${WATCHDOG_RUNNER}'" >/dev/null || die "未找到 ${WATCHDOG_RUNNER}"

  TERMUX_UID="$(run_root "ls -nd '${TERMUX_HOME}' | awk '{print \$3}'" | trim_cr)"
  TERMUX_GID="$(run_root "ls -nd '${TERMUX_HOME}' | awk '{print \$4}'" | trim_cr)"
  [[ "${TERMUX_UID}" =~ ^[0-9]+$ ]] || die "Termux uid 无效: ${TERMUX_UID}"
  [[ "${TERMUX_GID}" =~ ^[0-9]+$ ]] || die "Termux gid 无效: ${TERMUX_GID}"
  log "Termux 路径: ${TERMUX_BASE} (uid=${TERMUX_UID}, gid=${TERMUX_GID})"

  detect_push_base
  log "ADB 临时目录: ${PUSH_BASE}"
  if [[ "${PUSH_BASE}" != "/data/local/tmp" ]]; then
    warn "ADB 无法写入 /data/local/tmp，改用 ${PUSH_BASE}"
  fi

  if ! run_root "ping -c 1 -W 1 1.1.1.1 >/dev/null 2>&1 || ping -c 1 -W 1 223.5.5.5 >/dev/null 2>&1"; then
    warn "设备当前外网可能不可达；部署可继续，但 Feishu/模型访问可能失败"
  fi
  if ! run_root "ping -c 1 -W 1 open.feishu.cn >/dev/null 2>&1"; then
    warn "open.feishu.cn DNS/连通性检查失败；Feishu 可能报 ENOTFOUND"
  fi

  if ! run_root "test -x /system/bin/openclaw"; then
    warn "root shell 暂无 /system/bin/openclaw（部署后可能需要重启一次系统）"
  fi

  if ! run_root "/system/bin/sh '${GATEWAY_RUNNER}' status >/dev/null 2>&1"; then
    warn "gateway runner 当前 status 非成功；部署后会强制 start/restart"
  fi

  CHECK_STATUS="pass"
}

deploy() {
  local stamp tmp_local tmp_remote gateway_pid uid_line

  DEPLOY_STATUS="running"

  stamp="$(date +%s)"
  tmp_local="$(mktemp -d)"
  TMP_LOCAL_CLEANUP="${tmp_local}"
  tmp_remote="${PUSH_BASE}/openclaw-deploy-${stamp}"

  cat > "${tmp_local}/openclaw-root-entry.sh" <<EOF
#!/system/bin/sh
set -eu

TERMUX_PREFIX='${TERMUX_PREFIX}'
TERMUX_HOME='${TERMUX_HOME}'

export PREFIX="\$TERMUX_PREFIX"
export HOME="\$TERMUX_HOME"
export TMPDIR="\$TERMUX_PREFIX/tmp"
export PATH="\$TERMUX_PREFIX/bin:\$TERMUX_PREFIX/bin/applets:/system/bin:/system/xbin"

exec "\$TERMUX_PREFIX/bin/node" "\$TERMUX_PREFIX/lib/node_modules/openclaw/openclaw.mjs" "\$@"
EOF

  cat > "${tmp_local}/openclaw-wrapper.sh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
set -eu

ROOT_ENTRY='/data/adb/openclaw/openclaw-root-entry.sh'

quote_arg() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

cmd="/system/bin/sh $(quote_arg "$ROOT_ENTRY")"
for arg in "$@"; do
  cmd="$cmd $(quote_arg "$arg")"
done

exec su 0 -c "$cmd"
EOF

  cat > "${tmp_local}/openclaw-gateway.sh" <<EOF
#!/system/bin/sh
set -eu

RUNNER='${GATEWAY_RUNNER}'
ACTION="\${1:-start}"

if [ ! -x "\$RUNNER" ]; then
  echo "OpenClaw runner missing: \$RUNNER" >&2
  exit 1
fi

get_gateway_pid() {
  pids="\$(pidof openclaw-gateway 2>/dev/null || true)"
  [ -n "\$pids" ] || return 0
  echo "\$pids" | awk '{print \$1}'
}

gateway_uid() {
  pid="\$1"
  [ -n "\$pid" ] || return 0
  awk '/^Uid:/{print \$2}' "/proc/\$pid/status" 2>/dev/null || true
}

case "\$ACTION" in
  start)
    pid="\$(get_gateway_pid)"
    if [ -n "\$pid" ]; then
      uid="\$(gateway_uid "\$pid")"
      if [ "\${uid:-}" != "0" ]; then
        echo "detected non-root gateway pid=\$pid uid=\${uid:-unknown}; forcing restart as root" >&2
        exec /system/bin/sh "\$RUNNER" restart
      fi
    fi
    exec /system/bin/sh "\$RUNNER" start
    ;;
  stop|restart|status)
    exec /system/bin/sh "\$RUNNER" "\$ACTION"
    ;;
  *)
    echo "usage: \$0 {start|stop|restart|status}" >&2
    exit 2
    ;;
esac
EOF

  cat > "${tmp_local}/openclaw-gateway-watchdog.sh" <<EOF
#!/system/bin/sh
set -eu

WATCHDOG='${WATCHDOG_RUNNER}'
ACTION="\${1:-start}"

if [ ! -x "\$WATCHDOG" ]; then
  exit 0
fi

exec /system/bin/sh "\$WATCHDOG" "\$ACTION"
EOF

  cat > "${tmp_local}/module.prop" <<'EOF'
id=openclaw_cmd
name=OpenClaw Root Command
version=1.1.0
versionCode=110
author=local
summary=Expose openclaw command in root shell PATH
description=Adds /system/bin/openclaw via Magisk magic mount and runs OpenClaw with root-ready Termux env.
EOF

  cat > "${tmp_local}/openclaw-system-bin" <<'EOF'
#!/system/bin/sh
set -eu

ENTRY='/data/adb/openclaw/openclaw-root-entry.sh'
TERMUX_WRAPPER='/data/data/com.termux/files/usr/bin/openclaw'

if [ -x "$ENTRY" ]; then
  exec /system/bin/sh "$ENTRY" "$@"
fi

if [ -x "$TERMUX_WRAPPER" ]; then
  exec "$TERMUX_WRAPPER" "$@"
fi

echo 'openclaw launcher not found' >&2
exit 127
EOF

  cat > "${tmp_local}/remote-install.sh" <<EOF
#!/system/bin/sh
set -eu

STAMP='${stamp}'
TERMUX_UID='${TERMUX_UID}'
TERMUX_GID='${TERMUX_GID}'
TERMUX_WRAPPER='${TERMUX_PREFIX}/bin/openclaw'
REMOTE_DIR='${tmp_remote}'

mkdir -p /data/adb/openclaw
mkdir -p /data/adb/modules/openclaw_cmd/system/bin
mkdir -p /data/adb/service.d

if [ -f /data/adb/service.d/openclaw-gateway.sh ]; then
  cp /data/adb/service.d/openclaw-gateway.sh /data/adb/service.d/openclaw-gateway.sh.bak.oneclick.\$STAMP
fi
if [ -f /data/adb/service.d/openclaw-gateway-watchdog.sh ]; then
  cp /data/adb/service.d/openclaw-gateway-watchdog.sh /data/adb/service.d/openclaw-gateway-watchdog.sh.bak.oneclick.\$STAMP
fi
if [ -e "\$TERMUX_WRAPPER" ] && [ ! -e "\$TERMUX_WRAPPER.bak.oneclick.\$STAMP" ]; then
  cp "\$TERMUX_WRAPPER" "\$TERMUX_WRAPPER.bak.oneclick.\$STAMP"
fi

cp "\$REMOTE_DIR/openclaw-root-entry.sh" /data/adb/openclaw/openclaw-root-entry.sh
cp "\$REMOTE_DIR/openclaw-wrapper.sh" "\$TERMUX_WRAPPER"
cp "\$REMOTE_DIR/openclaw-gateway.sh" /data/adb/service.d/openclaw-gateway.sh
cp "\$REMOTE_DIR/openclaw-gateway-watchdog.sh" /data/adb/service.d/openclaw-gateway-watchdog.sh
cp "\$REMOTE_DIR/module.prop" /data/adb/modules/openclaw_cmd/module.prop
cp "\$REMOTE_DIR/openclaw-system-bin" /data/adb/modules/openclaw_cmd/system/bin/openclaw

chown root:root /data/adb/openclaw/openclaw-root-entry.sh
chmod 755 /data/adb/openclaw/openclaw-root-entry.sh

chown "\$TERMUX_UID:\$TERMUX_GID" "\$TERMUX_WRAPPER"
chmod 755 "\$TERMUX_WRAPPER"

chown root:root /data/adb/service.d/openclaw-gateway.sh /data/adb/service.d/openclaw-gateway-watchdog.sh
chmod 755 /data/adb/service.d/openclaw-gateway.sh /data/adb/service.d/openclaw-gateway-watchdog.sh

chown root:root /data/adb/modules/openclaw_cmd/module.prop /data/adb/modules/openclaw_cmd/system/bin/openclaw
chmod 644 /data/adb/modules/openclaw_cmd/module.prop
chmod 755 /data/adb/modules/openclaw_cmd/system/bin/openclaw
rm -f /data/adb/modules/openclaw_cmd/disable /data/adb/modules/openclaw_cmd/remove

/system/bin/sh -n /data/adb/service.d/openclaw-gateway.sh
/system/bin/sh -n /data/adb/service.d/openclaw-gateway-watchdog.sh
EOF

  chmod +x "${tmp_local}/remote-install.sh"

  log "推送部署文件到设备: ${tmp_remote}"
  run_adb shell "sh -c 'rm -rf \"${tmp_remote}\" && mkdir -p \"${tmp_remote}\"'" >/dev/null
  run_adb push "${tmp_local}/." "${tmp_remote}/" >/dev/null

  log "应用 root 化配置"
  run_root "/system/bin/sh '${tmp_remote}/remote-install.sh'" >/dev/null

  log "重启 gateway 与 watchdog"
  run_root "/system/bin/sh /data/adb/service.d/openclaw-gateway.sh start" >/dev/null
  run_root "/system/bin/sh /data/adb/service.d/openclaw-gateway-watchdog.sh restart || /system/bin/sh /data/adb/service.d/openclaw-gateway-watchdog.sh start" >/dev/null

  gateway_pid="$(run_root "pidof openclaw-gateway | awk '{print \$1}'" | trim_cr)"
  [[ -n "${gateway_pid}" ]] || die "openclaw-gateway 未运行"
  uid_line="$(run_root "awk '/^Uid:/{print \$2}' /proc/${gateway_pid}/status" | trim_cr)"
  [[ "${uid_line}" == "0" ]] || die "openclaw-gateway 未以 root 运行（uid=${uid_line}）"

  run_root "/system/bin/sh /data/adb/openclaw/openclaw-root-entry.sh gateway status --json >/dev/null" || die "gateway status 校验失败"
  run_root "/system/bin/sh /data/adb/openclaw/openclaw-root-entry.sh --version >/dev/null" || die "CLI 校验失败"

  if run_root "test -x /system/bin/openclaw"; then
    ROOT_CMD_STATE="ready"
  else
    ROOT_CMD_STATE="reboot_required"
  fi

  run_adb shell "sh -c 'rm -rf \"${tmp_remote}\"'" >/dev/null || true
  run_root "rm -rf '${tmp_remote}'" >/dev/null || true
  rm -rf "${tmp_local}"
  TMP_LOCAL_CLEANUP=""

  DEPLOY_GATEWAY_PID="${gateway_pid}"
  DEPLOY_GATEWAY_UID="${uid_line}"
  DEPLOY_STATUS="success"

  log "完成：Gateway PID=${gateway_pid} (uid=0)"
  log "Port: ${PORT}"
  if [[ "${ROOT_CMD_STATE}" == "ready" ]]; then
    log "root shell 可直接执行: openclaw --version"
  else
    log "root shell 入口待挂载，重启一次手机后即可直接执行: openclaw --version"
  fi
}

print_summary() {
  if (( ${#WARNINGS[@]} == 0 )); then
    log "兼容性检查结果: PASS（无告警）"
    return
  fi

  log "兼容性检查结果: PASS（${#WARNINGS[@]} 条告警）"
  for item in "${WARNINGS[@]}"; do
    printf '  - %s\n' "${item}"
  done
}

main() {
  parse_args "$@"
  compatibility_check
  print_summary

  if [[ "${MODE}" == "check" ]]; then
    DEPLOY_STATUS="not_run"
    log "check-only 模式结束，不做任何改动"
    if [[ "${REPORT_JSON}" == "1" ]]; then
      emit_json_report
    fi
    exit 0
  fi

  deploy
  if [[ "${REPORT_JSON}" == "1" ]]; then
    emit_json_report
  fi
}

main "$@"
