#!/usr/bin/env bash
# install.sh — DSH-m relay server-side installer (M2b-1 one-click deploy).
#
# Runs ON the Linux server as root (the Mac-side deploy engine pushes this file,
# the relay binary and the systemd unit, then invokes it through ssh/sudo).
#
# Non-destructive contract (m2b-plan §2.3), enforced by what this script touches:
#   - only /usr/local/bin/dshm-relay, /etc/dshm-relay/, /var/lib/dshm-relay/,
#     /etc/systemd/system/dshm-relay.service and the dshm-relay system user;
#   - only the dshm-relay unit is enabled/restarted; no other unit is touched;
#   - ports are chosen by the engine (busy ports are avoided, never stolen);
#   - idempotent upgrade keeps relay.yaml / TLS cert+key / relay.secret /
#     state.json; a repeated run with the same binary is a no-op (no restart);
#   - on failure the script rolls back what THIS run created (fresh install) or
#     restores the previous binary (upgrade).
#
# Usage (engine mode, machine readable):
#   sudo bash install.sh --engine --json-out /tmp/x/summary.json \
#     --public-host 203.0.113.10 --control-port 443 \
#     --bridge-start 30000 --bridge-end 30009 \
#     --binary /tmp/x/dshm-relay --unit-src /tmp/x/dshm-relay.service
#
# Human mode is the same command without --engine/--json-out; it prints a
# summary but never the relay secret in plaintext (it stays in relay.secret).
#
# Exit codes: 0 ok, 1 failure (rolled back), 2 usage error.
set -euo pipefail

log() { printf '[install] %s\n' "$*"; }
warn() { printf '[install] WARN: %s\n' "$*" >&2; }
die() { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }

ENGINE=0
JSON_OUT=""
PUBLIC_HOST=""
CONTROL_PORT="443"
BRIDGE_START="30000"
BRIDGE_END="30009"
BIN_SRC=""
UNIT_SRC=""
RELAY_USER="dshm-relay"
INSTALL_BIN="/usr/local/bin/dshm-relay"
CONFIG_DIR="/etc/dshm-relay"
DATA_DIR="/var/lib/dshm-relay"
UNIT_DST="/etc/systemd/system/dshm-relay.service"
FORCE_REINSTALL=0
FORCE_REINIT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine) ENGINE=1; shift ;;
    --json-out) JSON_OUT="${2:-}"; shift 2 ;;
    --public-host) PUBLIC_HOST="${2:-}"; shift 2 ;;
    --control-port) CONTROL_PORT="${2:-}"; shift 2 ;;
    --bridge-start) BRIDGE_START="${2:-}"; shift 2 ;;
    --bridge-end) BRIDGE_END="${2:-}"; shift 2 ;;
    --binary) BIN_SRC="${2:-}"; shift 2 ;;
    --unit-src) UNIT_SRC="${2:-}"; shift 2 ;;
    --user) RELAY_USER="${2:-}"; shift 2 ;;
    --install-bin) INSTALL_BIN="${2:-}"; shift 2 ;;
    --config-dir) CONFIG_DIR="${2:-}"; shift 2 ;;
    --data-dir) DATA_DIR="${2:-}"; shift 2 ;;
    --unit-dst) UNIT_DST="${2:-}"; shift 2 ;;
    --force-reinstall) FORCE_REINSTALL=1; shift ;;
    --force-reinit) FORCE_REINIT=1; shift ;;
    --help|-h)
      sed -n '2,40p' "$0"; exit 0 ;;
    *)
      # Backwards-compatible positional form: install.sh <public-host> [binary]
      if [[ -z "$PUBLIC_HOST" ]]; then PUBLIC_HOST="$1"; shift
      elif [[ -z "$BIN_SRC" ]]; then BIN_SRC="$1"; shift
      else die "未知参数: $1"; fi ;;
  esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
[[ "$(id -u)" -eq 0 ]] || die "需要 root / sudo 运行"
[[ -n "$PUBLIC_HOST" ]] || die "缺少 --public-host"
[[ -f "$BIN_SRC" ]] || die "找不到 relay 二进制: ${BIN_SRC:-<空>}"
[[ "$CONTROL_PORT" =~ ^[0-9]+$ ]] && (( CONTROL_PORT >= 1 && CONTROL_PORT <= 65535 )) || die "control 端口非法: $CONTROL_PORT"
[[ "$BRIDGE_START" =~ ^[0-9]+$ ]] && [[ "$BRIDGE_END" =~ ^[0-9]+$ ]] && (( BRIDGE_START >= 1 && BRIDGE_END <= 65535 && BRIDGE_START <= BRIDGE_END )) || die "bridge 端口段非法: $BRIDGE_START-$BRIDGE_END"
if [[ "$CONTROL_PORT" -ge "$BRIDGE_START" && "$CONTROL_PORT" -le "$BRIDGE_END" ]]; then
  die "control 端口 $CONTROL_PORT 落在 bridge 端口段 $BRIDGE_START-$BRIDGE_END 内"
fi
command -v systemctl >/dev/null 2>&1 || die "没有 systemd（systemctl 不存在）"

if [[ -z "$UNIT_SRC" ]]; then
  UNIT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dshm-relay.service"
fi
[[ -f "$UNIT_SRC" ]] || die "缺少 systemd unit 文件: $UNIT_SRC"

SHA_BIN=""
if command -v sha256sum >/dev/null 2>&1; then SHA_BIN="sha256sum"
elif command -v openssl >/dev/null 2>&1; then SHA_BIN="openssl-dgst"; fi
sha_of() {
  if [[ "$SHA_BIN" = "sha256sum" ]]; then sha256sum "$1" | awk '{print $1}';
  elif [[ "$SHA_BIN" = "openssl-dgst" ]]; then openssl dgst -sha256 "$1" | awk '{print $NF}';
  else echo "unavailable"; fi
}

VERSION_OF() {
  # $1 = binary path; prints the version token or "unknown"
  "$1" version 2>/dev/null | awk '{print $2}' | head -1 || true
}

# ---------------------------------------------------------------------------
# State discovery (what existed before this run)
# ---------------------------------------------------------------------------
CONFIG_FILE="$CONFIG_DIR/relay.yaml"
HAD_USER=0; HAD_CONFIG_DIR=0; HAD_DATA_DIR=0; HAD_BIN=0; HAD_CONFIG=0; HAD_UNIT=0; HAD_ACTIVE=0
id -u "$RELAY_USER" >/dev/null 2>&1 && HAD_USER=1
test -d "$CONFIG_DIR" && HAD_CONFIG_DIR=1
test -d "$DATA_DIR" && HAD_DATA_DIR=1
test -f "$INSTALL_BIN" && HAD_BIN=1
test -f "$CONFIG_FILE" && HAD_CONFIG=1
test -f "$UNIT_DST" && HAD_UNIT=1
systemctl is-active dshm-relay >/dev/null 2>&1 && HAD_ACTIVE=1

MODE="fresh"
if [[ "$HAD_CONFIG" -eq 1 || "$HAD_BIN" -eq 1 || "$HAD_UNIT" -eq 1 ]]; then MODE="upgrade"; fi
log "mode=$MODE (user=$HAD_USER config_dir=$HAD_CONFIG_DIR data_dir=$HAD_DATA_DIR bin=$HAD_BIN config=$HAD_CONFIG unit=$HAD_UNIT active=$HAD_ACTIVE)"

BIN_SHA_NEW="$(sha_of "$BIN_SRC")"
[[ "$BIN_SHA_NEW" != "unavailable" ]] || die "服务器缺少 sha256sum/openssl，无法校验二进制"
BIN_SHA_OLD=""
[[ "$HAD_BIN" -eq 1 ]] && BIN_SHA_OLD="$(sha_of "$INSTALL_BIN")"

CREATED_USER=0; CREATED_CONFIG_DIR=0; CREATED_DATA_DIR=0; CREATED_BIN=0; CREATED_CONFIG=0; CREATED_UNIT=0
BACKUP_BIN=""
SERVICE_RESTARTED=0
ACTION="noop"

INIT_JSON=""
WORK="$(mktemp -d /tmp/dshm-relay-install.XXXXXX)"
chmod 0700 "$WORK"
cleanup_work() { rm -rf "$WORK"; }

SUMMARY_WRITE_FAILED=0
write_summary_failure() {
  [[ "$ENGINE" -eq 1 && -n "$JSON_OUT" ]] || return 0
  printf '{\n  "ok": false,\n  "mode": "%s",\n  "failedAt": "%s",\n  "version": "%s"\n}\n' \
    "$MODE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(VERSION_OF "$BIN_SRC" 2>/dev/null || echo unknown)" > "$JSON_OUT" 2>/dev/null || true
  chmod 0600 "$JSON_OUT" 2>/dev/null || true
}

rollback() {
  local rc=$?
  if [[ $rc -eq 0 ]]; then return 0; fi
  trap - EXIT
  printf '\n[install] FAILED (exit %d) — rolling back resources created by this run\n' "$rc" >&2
  set +e
  write_summary_failure
  if [[ "$MODE" = "fresh" ]]; then
    if [[ "$CREATED_UNIT" -eq 1 || "$HAD_UNIT" -eq 0 ]]; then
      systemctl stop dshm-relay >/dev/null 2>&1
      systemctl disable dshm-relay >/dev/null 2>&1
      rm -f "$UNIT_DST"
    fi
    systemctl daemon-reload >/dev/null 2>&1
    if [[ "$CREATED_BIN" -eq 1 ]]; then rm -f "$INSTALL_BIN"; fi
    if [[ "$CREATED_CONFIG" -eq 1 ]]; then rm -f "$CONFIG_FILE"; fi
    if [[ "$CREATED_CONFIG_DIR" -eq 1 && "$HAD_CONFIG_DIR" -eq 0 ]]; then rm -rf "$CONFIG_DIR"; fi
    if [[ "$CREATED_DATA_DIR" -eq 1 && "$HAD_DATA_DIR" -eq 0 ]]; then rm -rf "$DATA_DIR"; fi
    if [[ "$CREATED_USER" -eq 1 && "$HAD_USER" -eq 0 ]]; then userdel "$RELAY_USER" >/dev/null 2>&1 || true; fi
  else
    if [[ -n "$BACKUP_BIN" && -f "$BACKUP_BIN" ]]; then
      install -m 0755 -o root -g root "$BACKUP_BIN" "$INSTALL_BIN"
      systemctl restart dshm-relay >/dev/null 2>&1 || true
      log "已从备份恢复旧二进制: $BACKUP_BIN"
    fi
    if [[ "$CREATED_UNIT" -eq 1 && "$HAD_UNIT" -eq 0 ]]; then rm -f "$UNIT_DST"; systemctl daemon-reload >/dev/null 2>&1; fi
  fi
  cleanup_work
  printf '[install] rollback done\n' >&2
  exit "$rc"
}
trap rollback EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------------------
# 1. system user + directories
# ---------------------------------------------------------------------------
if [[ "$HAD_USER" -eq 0 ]]; then
  log "创建系统用户 $RELAY_USER"
  useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin --user-group "$RELAY_USER"
  CREATED_USER=1
fi
if [[ "$HAD_DATA_DIR" -eq 0 ]]; then CREATED_DATA_DIR=1; fi
install -d -m 0700 -o "$RELAY_USER" -g "$RELAY_USER" "$DATA_DIR"
install -d -m 0700 -o "$RELAY_USER" -g "$RELAY_USER" "$DATA_DIR/tls"
# /etc/dshm-relay must be traversable by the service user: 0750 root:dshm-relay
# (0755 root:root causes config permission denied; 0750 root:root crashes too).
if [[ "$HAD_CONFIG_DIR" -eq 0 ]]; then CREATED_CONFIG_DIR=1; fi
install -d -m 0750 -o root -g "$RELAY_USER" "$CONFIG_DIR"
chgrp "$RELAY_USER" "$CONFIG_DIR" 2>/dev/null || true
chmod 0750 "$CONFIG_DIR"
log "目录就绪: $CONFIG_DIR (0750 root:$RELAY_USER) / $DATA_DIR (0700 $RELAY_USER)"

# ---------------------------------------------------------------------------
# 2. binary (backup old first on upgrade)
# ---------------------------------------------------------------------------
if [[ "$MODE" = "upgrade" && "$HAD_BIN" -eq 1 && "$BIN_SHA_OLD" != "$BIN_SHA_NEW" ]]; then
  mkdir -p "$DATA_DIR/backup"
  BACKUP_BIN="$DATA_DIR/backup/dshm-relay.$(date -u +%Y%m%d%H%M%S)"
  cp -a "$INSTALL_BIN" "$BACKUP_BIN"
  chmod 0700 "$BACKUP_BIN"
  log "已备份旧二进制: $BACKUP_BIN"
fi
install -m 0755 -o root -g root "$BIN_SRC" "$INSTALL_BIN"
[[ "$HAD_BIN" -eq 0 ]] && CREATED_BIN=1
BIN_VERSION="$(VERSION_OF "$INSTALL_BIN")"
log "已安装二进制: $INSTALL_BIN (version ${BIN_VERSION:-unknown}, sha256 ${BIN_SHA_NEW:0:12}…)"

# ---------------------------------------------------------------------------
# 3. first-run config (fresh) — existing config is never touched on upgrade
# ---------------------------------------------------------------------------
if [[ "$HAD_CONFIG" -eq 0 || "$FORCE_REINIT" -eq 1 ]]; then
  log "首次配置：生成 relay.yaml / TLS 证书 / relay.secret（secret 只写入 0600 文件与本次摘要）"
  INIT_OUT="$WORK/init.json"
  "$INSTALL_BIN" init \
    --public-host "$PUBLIC_HOST" \
    --control-listen "0.0.0.0:${CONTROL_PORT}" \
    --bridge-ports "0.0.0.0:${BRIDGE_START}-${BRIDGE_END}" \
    --out "$DATA_DIR" \
    ${FORCE_REINIT:+--force} \
    --print-json > "$INIT_OUT" 2>"$WORK/init.err" || {
      cat "$WORK/init.err" >&2 || true
      die "relay init 失败"
    }
  chmod 0600 "$INIT_OUT"
  INIT_JSON="$(cat "$INIT_OUT")"
  rm -f "$INIT_OUT"
  mv "$DATA_DIR/relay.yaml" "$CONFIG_FILE"
  chown root:"$RELAY_USER" "$CONFIG_FILE"
  chmod 0640 "$CONFIG_FILE"
  chown -R "$RELAY_USER":"$RELAY_USER" "$DATA_DIR"
  if [[ "$HAD_CONFIG" -eq 0 ]]; then CREATED_CONFIG=1; fi
  ACTION="init"
else
  log "已存在 $CONFIG_FILE：保留证书 / secret / state（幂等升级）"
  chown root:"$RELAY_USER" "$CONFIG_FILE" 2>/dev/null || true
  chmod 0640 "$CONFIG_FILE" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 4. systemd unit — only our own unit is installed/enabled
# ---------------------------------------------------------------------------
install -m 0644 -o root -g root "$UNIT_SRC" "$UNIT_DST"
[[ "$HAD_UNIT" -eq 0 ]] && CREATED_UNIT=1
systemctl daemon-reload
# Enabling our own unit is idempotent; it never touches another service.
systemctl enable dshm-relay >/dev/null

# ---------------------------------------------------------------------------
# 5. start / upgrade decision
# ---------------------------------------------------------------------------
NEED_RESTART=1
if [[ "$MODE" = "upgrade" && "$FORCE_REINSTALL" -eq 0 && "$HAD_ACTIVE" -eq 1 && "$BIN_SHA_OLD" = "$BIN_SHA_NEW" ]]; then
  NEED_RESTART=0
  ACTION="noop"
  log "二进制未变化且服务运行中：跳过重启（幂等）"
fi
if [[ "$NEED_RESTART" -eq 1 ]]; then
  log "启动/重启 dshm-relay"
  systemctl restart dshm-relay
  SERVICE_RESTARTED=1
  ACTION="$( [[ "$ACTION" = "init" ]] && echo "fresh-install" || echo "upgrade" )"
fi

# ---------------------------------------------------------------------------
# 6. local health check (control channel + bridge listener)
# ---------------------------------------------------------------------------
HEALTH_OK=0
HEALTH_TEXT=""
if command -v curl >/dev/null 2>&1; then
  for _ in $(seq 1 24); do
    HEALTH_TEXT="$(curl -fsSk --max-time 3 "https://127.0.0.1:${CONTROL_PORT}/healthz" 2>/dev/null || true)"
    if printf '%s' "$HEALTH_TEXT" | grep -q '"ok":true'; then HEALTH_OK=1; break; fi
    sleep 0.5
  done
else
  for _ in $(seq 1 24); do
    if ss -lntH 2>/dev/null | grep -q ":${CONTROL_PORT} "; then HEALTH_OK=2; break; fi
    sleep 0.5
  done
  HEALTH_TEXT="(curl 不可用，按监听端口判断)"
fi
if [[ "$HEALTH_OK" -eq 0 ]]; then
  warn "本机 healthz 自检失败: https://127.0.0.1:${CONTROL_PORT}/healthz"
  warn "journalctl -u dshm-relay 最近输出："
  journalctl -u dshm-relay -n 30 --no-pager >&2 2>/dev/null || true
  die "relay 启动后健康检查失败"
fi
log "本机健康检查通过: https://127.0.0.1:${CONTROL_PORT}/healthz"
if ! ss -lntH 2>/dev/null | grep -q ":${BRIDGE_START} "; then
  warn "bridge 端口 $BRIDGE_START 当前未监听（relay 在 Mac 隧道连接后才绑定 bridge 端口，属正常）"
fi

# ---------------------------------------------------------------------------
# 7. summary (pin / controlOrigin / appConfig / changed flags)
# ---------------------------------------------------------------------------
PIN=""
if [[ -n "$INIT_JSON" ]]; then
  PIN="$(printf '%s' "$INIT_JSON" | sed -n 's/.*"pin":"\([^"]*\)".*/\1/p')"
else
  PIN="$("$INSTALL_BIN" doctor --config "$CONFIG_FILE" 2>&1 | sed -n 's/.*tls pin: \([A-Za-z0-9_-]*\) .*/\1/p' | head -1 || true)"
fi
[[ -n "$PIN" ]] || warn "无法从配置中读出证书 pin（继续，引擎会从 init 摘要或外网 TLS 校验）"
CONTROL_ORIGIN="https://${PUBLIC_HOST}:${CONTROL_PORT}"
APP_CONFIG="dshm-relay://${PUBLIC_HOST}:${CONTROL_PORT}?pin=${PIN}&v=1"

if [[ "$SERVICE_RESTARTED" -eq 0 ]]; then HEALTH_OK=1; fi

summary() {
  # Prefer embedding the one-line init JSON verbatim (valid JSON) for fresh runs.
  local init_part=""
  if [[ -n "$INIT_JSON" ]]; then init_part=",
  \"init\": ${INIT_JSON}"; fi
  cat <<EOF
{
  "ok": true,
  "engine": ${ENGINE},
  "mode": "${MODE}",
  "action": "${ACTION}",
  "version": "${BIN_VERSION:-unknown}",
  "publicHost": "${PUBLIC_HOST}",
  "controlPort": ${CONTROL_PORT},
  "controlOrigin": "${CONTROL_ORIGIN}",
  "bridgeRange": "${BRIDGE_START}-${BRIDGE_END}",
  "pin": "${PIN}",
  "appConfig": "${APP_CONFIG}",
  "installBin": "${INSTALL_BIN}",
  "configFile": "${CONFIG_FILE}",
  "dataDir": "${DATA_DIR}",
  "unitPath": "${UNIT_DST}",
  "healthOk": ${HEALTH_OK},
  "restarted": ${SERVICE_RESTARTED},
  "binarySha256": "${BIN_SHA_NEW}",
  "changed": {
    "user": ${CREATED_USER},
    "configDir": ${CREATED_CONFIG_DIR},
    "dataDir": ${CREATED_DATA_DIR},
    "binary": $([[ "$MODE" = "fresh" || "$BIN_SHA_OLD" != "$BIN_SHA_NEW" ]] && echo 1 || echo 0),
    "config": ${CREATED_CONFIG},
    "unit": ${CREATED_UNIT}
  },
  "had": {
    "user": ${HAD_USER},
    "config": ${HAD_CONFIG},
    "binary": ${HAD_BIN},
    "unit": ${HAD_UNIT},
    "active": ${HAD_ACTIVE}
  },
  "backupPath": "${BACKUP_BIN}"
  ${init_part}
}
EOF
}

if [[ "$ENGINE" -eq 1 && -n "$JSON_OUT" ]]; then
  summary > "$WORK/summary.json"
  chmod 0600 "$WORK/summary.json"
  # Same filesystem move when possible; JSON_OUT is normally inside our tmp dir.
  cp "$WORK/summary.json" "$JSON_OUT"
  chmod 0600 "$JSON_OUT"
  log "摘要已写入 $JSON_OUT（含 secret，仅 root 可读，引擎读取后会删除）"
else
  echo
  echo "===== dshm-relay 部署完成 ====="
  echo "  控制地址:   $CONTROL_ORIGIN   (TLS, ALPN dshm-relay/1)"
  echo "  bridge 端口: 0.0.0.0:${BRIDGE_START}-${BRIDGE_END} (TCP)"
  echo "  证书 pin:   ${PIN:-<见证书>}"
  echo "  App 服务器配置: $APP_CONFIG"
  echo "  配置:       $CONFIG_FILE"
  echo "  secret:     $DATA_DIR/relay.secret (0600，内容不打印)"
  echo
  echo "云安全组/防火墙需手工放行入站 TCP ${CONTROL_PORT} 与 TCP ${BRIDGE_START}-${BRIDGE_END}。"
fi

trap - EXIT
cleanup_work
log "完成 (mode=$MODE action=$ACTION restarted=$SERVICE_RESTARTED)"
exit 0
