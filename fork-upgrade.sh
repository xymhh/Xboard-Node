#!/usr/bin/env bash
# xboard-node（xymhh fork）一键升级脚本
#
# 用法（节点机上，root）：
#   curl -fsSL https://raw.githubusercontent.com/xymhh/Xboard-Node/dev/fork-upgrade.sh | sudo bash
#
# 做的事：从 GitHub Release 取 xboard-node 二进制（默认取最新 Release），
#         备份系统里那份 → 替换 → 重启 systemd 服务 → 健康检查；
#         起不来就自动回滚到替换前的二进制。
#
# 参数：
#   --tag v1.13-xymhh.2   指定版本（默认 latest = 仓库最新 Release）
#   --rollback            回滚到最近一次备份
#   --dry-run             只下载 + 自检，不落盘、不重启
#   -h | --help           帮助
#
# 可用环境变量覆盖默认值：
#   XB_REPO=xymhh/Xboard-Node     XB_BIN=/usr/local/bin/xboard-node
#   XB_SERVICE=xboard-node        XB_CONFIG=/etc/xboard-node/config.yml
#   XB_BACKUP_DIR=/etc/xboard-node/backups/manual
#   XB_SERVICE=  （空字符串 = 不动 systemd，仅换文件；测试/容器里用）
set -Eeuo pipefail

REPO="${XB_REPO:-xymhh/Xboard-Node}"
BIN="${XB_BIN:-/usr/local/bin/xboard-node}"
SERVICE="${XB_SERVICE-xboard-node}"
CONFIG="${XB_CONFIG:-/etc/xboard-node/config.yml}"
BACKUP_DIR="${XB_BACKUP_DIR:-/etc/xboard-node/backups/manual}"
TAG="latest"
DRY_RUN=0
ROLLBACK=0

log()  { printf '\033[32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,20p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' || true
}

version_of() {
    if [ -x "$1" ]; then
        "$1" -v 2>/dev/null | head -1
    else
        echo "（未安装）"
    fi
}

health_port() {
    [ -f "$CONFIG" ] || return 0
    local parsed=""
    if [ -x /usr/local/bin/xbctl ]; then
        parsed=$(/usr/local/bin/xbctl config health-port --config "$CONFIG" 2>/dev/null || true)
    fi
    if [ -z "$parsed" ]; then
        parsed=$(grep -m1 'health_port:' "$CONFIG" 2>/dev/null | sed 's/.*health_port:[[:space:]]*//' | tr -cd '0-9' || true)
    fi
    printf '%s' "$parsed"
}

restart_and_check() {
    if [ -z "$SERVICE" ]; then
        warn "XB_SERVICE 为空：跳过 systemd 重启与健康检查"
        return 0
    fi
    systemctl restart "$SERVICE" || return 1
    local port attempt=0
    port=$(health_port)
    while [ "$attempt" -lt 20 ]; do
        if ! systemctl is-active "$SERVICE" >/dev/null 2>&1; then
            sleep 1
            attempt=$((attempt + 1))
            continue
        fi
        if [ -n "$port" ] && [ "$port" -gt 0 ] 2>/dev/null; then
            curl -fsS "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1 || {
                sleep 1
                attempt=$((attempt + 1))
                continue
            }
        fi
        return 0
    done
    return 1
}

latest_backup() {
    ls -1t "${BACKUP_DIR}"/xboard-node-* 2>/dev/null | head -1 || true
}

while [ $# -gt 0 ]; do
    case "$1" in
        --tag)      TAG="${2:?--tag 需要一个版本号}"; shift 2 ;;
        --rollback) ROLLBACK=1; shift ;;
        --dry-run)  DRY_RUN=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          die "未知参数：$1（用 -h 看帮助）" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "需要 root 权限，请用 sudo 运行"

case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) die "不支持的架构：$(uname -m)（只提供 linux/amd64 与 linux/arm64）" ;;
esac

# ── 回滚分支 ──
if [ "$ROLLBACK" -eq 1 ]; then
    backup=$(latest_backup)
    [ -n "$backup" ] || die "找不到备份：${BACKUP_DIR}/xboard-node-*"
    log "回滚到：${backup}（$(version_of "$backup")）"
    install -m755 "$backup" "$BIN"
    if ! restart_and_check; then
        die "回滚后服务仍不健康，请手动查：journalctl -u ${SERVICE} -n 50"
    fi
    log "回滚完成，当前：$(version_of "$BIN")"
    exit 0
fi

if [ "$TAG" = "latest" ]; then
    URL="https://github.com/${REPO}/releases/latest/download/xboard-node-linux-${ARCH}"
else
    URL="https://github.com/${REPO}/releases/download/${TAG}/xboard-node-linux-${ARCH}"
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

log "架构 ${ARCH}，下载：${URL}"
curl -fL --retry 3 --connect-timeout 20 -o "$TMP_DIR/xboard-node" "$URL" \
    || die "下载失败（到 GitHub 的网络不通？可加 -4 重试或手动 scp 二进制后 --tag 指定）"
chmod +x "$TMP_DIR/xboard-node"

NEW_VER=$("$TMP_DIR/xboard-node" -v 2>/dev/null | head -1 || true)
[ -n "$NEW_VER" ] || die "下载的文件无法运行（架构不对或文件损坏）"
OLD_VER=$(version_of "$BIN")

log "当前：${OLD_VER}"
log "目标：${NEW_VER}"

if [ "$DRY_RUN" -eq 1 ]; then
    log "--dry-run：只下载与自检，未落盘、未重启"
    exit 0
fi

if [ -x "$BIN" ]; then
    mkdir -p "$BACKUP_DIR"
    backup="${BACKUP_DIR}/xboard-node-$(date +%Y%m%d-%H%M%S)"
    cp "$BIN" "$backup"
    log "已备份旧二进制：${backup}"
fi

install -m755 "$TMP_DIR/xboard-node" "$BIN"
log "已替换 ${BIN}"

if ! restart_and_check; then
    warn "重启后不健康，自动回滚"
    if [ -n "${backup:-}" ] && [ -f "$backup" ]; then
        install -m755 "$backup" "$BIN"
        restart_and_check || warn "回滚后仍不健康，请查：journalctl -u ${SERVICE} -n 50"
        die "升级失败，已回滚到 ${OLD_VER}"
    fi
    die "升级失败且无备份可回滚，请查：journalctl -u ${SERVICE} -n 50"
fi

log "升级完成：${OLD_VER} → ${NEW_VER}"
if [ -n "$SERVICE" ]; then
    log "验证修复是否生效：面板改一次自定义出口，然后 journalctl -u ${SERVICE} -f 应看到 rebuilding kernel，且 PID 不变"
fi
