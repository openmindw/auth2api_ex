t#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# auth2api_ex-elixir 一键部署 / 升级脚本
#
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/openmindw/auth2api_ex/main/scripts/install.sh | bash
#   bash install.sh                   # 安装最新版
#   bash install.sh v1.0.2            # 安装指定版本
#   bash install.sh v1.0.2 -t ghp_xxx # 私有仓库需 GitHub token
#
# 环境变量（可选）:
#   GITHUB_TOKEN         GitHub token（私有仓库必需）
#   DEPLOY_DIR           安装目录（默认 /opt/auth2api_ex-elixir）
#   AUTH_DIR             OAuth 数据目录（默认 ~/.auth2api_ex-elixir）
#   CONFIG_YAML          配置文件路径（默认 /opt/auth2api_ex-elixir/config.yaml）
#   SERVICE_PORT         服务端口（默认 8318）
#   SERVICE_NAME         systemd 服务名（默认 auth2api_ex-elixir）
#   APP_NAME             GitHub Release 中的 release 名（默认 auth2api_ex）
# ============================================================

# ============================================================
# 开源后请修改这里
# ============================================================
GITHUB_REPO="openmindw/auth2api_ex"

# ── 参数解析 ────────────────────────────────────────────────
VERSION="${1:-latest}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--token) GITHUB_TOKEN="$2"; shift 2 ;;
    -t=*|--token=*) GITHUB_TOKEN="${1#*=}"; shift ;;
    *) shift ;;
  esac
done

# ── 默认配置 ────────────────────────────────────────────────
DEPLOY_DIR="${DEPLOY_DIR:-/opt/auth2api_ex-elixir}"
AUTH_DIR="${AUTH_DIR:-$HOME/.auth2api_ex-elixir}"
SERVICE_PORT="${SERVICE_PORT:-8318}"
SERVICE_NAME="${SERVICE_NAME:-auth2api_ex-elixir}"
UPDATER_SERVICE="${SERVICE_NAME}-updater"
APP_NAME="${APP_NAME:-auth2api_ex}"
CONFIG_YAML="${CONFIG_YAML:-${DEPLOY_DIR}/config.yaml}"
ENV_FILE="${DEPLOY_DIR}/.env"
STAGING="${DEPLOY_DIR}/.upgrade-staging"
PREVIOUS="${DEPLOY_DIR}/previous"
STATUS_FILE="${DEPLOY_DIR}/update-status.json"
BIN_DIR="${DEPLOY_DIR}/bin"

# ── 颜色 ────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${BLUE}==>${NC} $*"; }
ok()   { echo -e "${GREEN}==>${NC} ✓ $*"; }
warn() { echo -e "${YELLOW}==>${NC} ⚠ $*"; }
die()  { echo -e "${RED}==>${NC} ✗ $*"; exit 1; }

# ── 平台检测 ────────────────────────────────────────────────
detect_target() {
  local arch os
  arch=$(uname -m)
  os=$(uname -s | tr '[:upper:]' '[:lower:]')

  case "${os}/${arch}" in
    linux/x86_64)   echo "linux-amd64"   ;;
    linux/aarch64)  echo "linux-arm64"   ;;
    linux/arm64)    echo "linux-arm64"   ;;
    darwin/x86_64)  echo "darwin-amd64"  ;;
    darwin/arm64)   echo "darwin-arm64"  ;;
    *) die "不支持的平台: ${os}/${arch}" ;;
  esac
}

TARGET=$(detect_target)
log "平台: ${TARGET}"

# ── 权限 ────────────────────────────────────────────────────
if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
  log "使用 sudo"
fi

# ── GitHub API ──────────────────────────────────────────────
api() {
  local opts=(-fsSL)
  [[ -n "${GITHUB_TOKEN}" ]] && opts+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  curl "${opts[@]}" "$@"
}

# ── 获取版本信息 ────────────────────────────────────────────
log "获取版本信息..."

if [[ "${VERSION}" == "latest" ]]; then
  RELEASE_JSON=$(api "https://api.github.com/repos/${GITHUB_REPO}/releases/latest") || \
    die "无法访问 GitHub Release（检查仓库名、网络、或 token）"
  TAG=$(echo "${RELEASE_JSON}" | grep '"tag_name"' | head -1 | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
else
  TAG="${VERSION}"
  RELEASE_JSON=$(api "https://api.github.com/repos/${GITHUB_REPO}/releases/tags/${TAG}") || \
    die "找不到版本: ${TAG}"
fi

[[ -z "${TAG}" ]] && die "无法解析 tag"

log "版本: ${TAG}"

# ── 获取下载 URL ────────────────────────────────────────────
ASSET="auth2api_ex-${TARGET}.tar.gz"
SHA_ASSET="${ASSET}.sha256"

DOWNLOAD_URL=$(echo "${RELEASE_JSON}" | grep '"browser_download_url"' | grep "${ASSET}" | head -1 | sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/')
SHA_URL=$(     echo "${RELEASE_JSON}" | grep '"browser_download_url"' | grep "${SHA_ASSET}" | head -1 | sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/')

[[ -z "${DOWNLOAD_URL}" ]] && die "找不到 ${ASSET}（平台 ${TARGET} 尚未构建？）"

log "下载 ${ASSET}"

# ── 下载 ────────────────────────────────────────────────────
TMP_DIR=$(mktemp -d)
trap 'rm -rf ${TMP_DIR}' EXIT

download() {
  local url="$1" dest="$2" label="$3"
  log "  → ${label}"
  api -o "${dest}" "${url}" || die "下载失败: ${label}"
}

download "${DOWNLOAD_URL}" "${TMP_DIR}/${ASSET}"      "${ASSET}"
download "${SHA_URL}"      "${TMP_DIR}/${SHA_ASSET}"  "${SHA_ASSET}"

# ── 校验 sha256 ─────────────────────────────────────────────
log "校验 sha256..."

cd "${TMP_DIR}"
EXPECTED=$(awk '{print $1}' "${SHA_ASSET}")

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL=$(sha256sum "${ASSET}" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL=$(shasum -a 256 "${ASSET}" | awk '{print $1}')
else
  die "未找到 sha256sum 或 shasum"
fi

[[ "${EXPECTED}" == "${ACTUAL}" ]] || die "sha256 校验失败！包可能被篡改"
ok "sha256 通过"

# ── 创建目录 ────────────────────────────────────────────────
log "准备目录..."
$SUDO mkdir -p "${DEPLOY_DIR}" "${AUTH_DIR}" "${BIN_DIR}"
$SUDO chown -R "$(whoami):$(id -gn)" "${DEPLOY_DIR}" 2>/dev/null || true
mkdir -p "${AUTH_DIR}"

# ── 解压到 staging ──────────────────────────────────────────
log "解压到 staging..."
$SUDO rm -rf "${STAGING}"
mkdir -p "${STAGING}"
tar -xzf "${ASSET}" -C "${STAGING}"

# 检查完整性
for item in bin lib releases; do
  [[ -e "${STAGING}/${item}" ]] || die "release 包不完整: 缺少 ${item}/"
done

RELEASE_BIN=$(ls "${STAGING}/bin/" | grep -v '\.' | head -1)
[[ -f "${STAGING}/bin/${RELEASE_BIN}" ]] || die "release 包不完整: 无可执行文件"

ok "release 包结构完整"

# ── 停旧服务 ────────────────────────────────────────────────
if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
  log "停止现有服务..."
  $SUDO systemctl stop "${SERVICE_NAME}"
  sleep 2
fi

# ── 备份旧版本 ──────────────────────────────────────────────
if [[ -d "${DEPLOY_DIR}/lib" ]]; then
  log "备份当前版本到 previous/"
  $SUDO rm -rf "${PREVIOUS}"
  mkdir -p "${PREVIOUS}"
  for item in bin lib releases; do
    [[ -e "${DEPLOY_DIR}/${item}" ]] && mv "${DEPLOY_DIR}/${item}" "${PREVIOUS}/${item}" 2>/dev/null || $SUDO mv "${DEPLOY_DIR}/${item}" "${PREVIOUS}/${item}"
  done
  for ertsdir in "${DEPLOY_DIR}"/erts-*; do
    [[ -e "${ertsdir}" ]] && { mv "${ertsdir}" "${PREVIOUS}/" 2>/dev/null || $SUDO mv "${ertsdir}" "${PREVIOUS}/"; }
  done
  ok "已备份"
fi

# ── 安装新版本 ──────────────────────────────────────────────
log "安装 ${TAG}..."
for item in bin lib releases; do
  mv "${STAGING}/${item}" "${DEPLOY_DIR}/${item}" 2>/dev/null || $SUDO mv "${STAGING}/${item}" "${DEPLOY_DIR}/${item}"
done
for ertsdir in "${STAGING}"/erts-*; do
  [[ -e "${ertsdir}" ]] && { mv "${ertsdir}" "${DEPLOY_DIR}/" 2>/dev/null || $SUDO mv "${ertsdir}" "${DEPLOY_DIR}/"; }
done

rm -rf "${STAGING}"

# ── 配置文件（首次部署）─────────────────────────────────────
if [[ ! -f "${CONFIG_YAML}" ]]; then
  log "生成默认配置文件..."
  $SUDO tee "${CONFIG_YAML}" > /dev/null <<CONFEOF
host: "127.0.0.1"
port: ${SERVICE_PORT}

auth-dir: "~/.auth2api_ex-elixir"

api-keys:
  - "sk-change-me"

admin:
  username: "admin"
  password: "change-me"

body-limit: "200mb"

timeouts:
  messages-ms: 120000
  stream-messages-ms: 600000
  count-tokens-ms: 30000

debug: "off"

cloaking:
  cli-version: "2.1.88"
  entrypoint: "cli"
CONFEOF
  ok "配置文件已生成: ${CONFIG_YAML}"
  warn "请修改 admin 密码和 api-keys"
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "AUTH2API_CONFIG=${CONFIG_YAML}" > "${ENV_FILE}"
  ok ".env 已创建"
fi

# ── systemd 主服务 ──────────────────────────────────────────
log "配置 systemd..."

$SUDO tee "/etc/systemd/system/${SERVICE_NAME}.service" > /dev/null <<SVCEOF
[Unit]
Description=auth2api_ex — AI API Gateway
After=network.target

[Service]
Type=exec
User=$(whoami)
Group=$(id -gn)
WorkingDirectory=${DEPLOY_DIR}
EnvironmentFile=-${ENV_FILE}
Environment=LANG=en_US.UTF-8
Environment=HOME=${HOME}
ExecStart=${DEPLOY_DIR}/bin/${RELEASE_BIN} start
ExecStop=${DEPLOY_DIR}/bin/${RELEASE_BIN} stop
Restart=on-failure
RestartSec=5
SyslogIdentifier=${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
SVCEOF

ok "${SERVICE_NAME}.service"

# ── updater 脚本 ────────────────────────────────────────────
log "安装 updater..."

cat > "${BIN_DIR}/auth2api_ex-updater" <<'UPDEOF'
#!/usr/bin/env bash
set -euo pipefail

# auth2api_ex auto updater — 由 systemd oneshot 调用
# 从 update-status.json 读取参数，完成下载→校验→替换→重启→健康检查→回滚

DEPLOY_DIR="${DEPLOY_DIR:-/opt/auth2api_ex-elixir}"
STATUS_FILE="${DEPLOY_DIR}/update-status.json"
STAGING="${DEPLOY_DIR}/.upgrade-staging"
PREVIOUS="${DEPLOY_DIR}/previous"
TMP_DIR="/tmp/auth2api_ex-update"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:8318/admin/api/version}"

set_status() {
  cat > "${STATUS_FILE}" <<EOF
{"status":"${1}","message":"${2}","updated_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
  echo "[updater] ${1}: ${2}"
}

# 读取参数
[[ -f "${STATUS_FILE}" ]] || { set_status failed "status file missing"; exit 1; }

DOWNLOAD_URL=$(grep -o '"download_url":"[^"]*"' "${STATUS_FILE}" | head -1 | sed 's/"download_url":"//;s/"//')
SHA_URL=$(     grep -o '"sha256_url":"[^"]*"'   "${STATUS_FILE}" | head -1 | sed 's/"sha256_url":"//;s/"//')
TO_VERSION=$(  grep -o '"to":"[^"]*"'           "${STATUS_FILE}" | head -1 | sed 's/"to":"//;s/"//')
TARGET=$(      grep -o '"target":"[^"]*"'       "${STATUS_FILE}" | head -1 | sed 's/"target":"//;s/"//')
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

ASSET="auth2api_ex-${TARGET}.tar.gz"

# ── 下载 ───────────────────────────────────────
set_status downloading "Downloading ${TO_VERSION}..."
rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"

dl() { local opts=(-fsSL -o "$1"); [[ -n "${GITHUB_TOKEN}" ]] && opts+=(-H "Authorization: Bearer ${GITHUB_TOKEN}"); curl "${opts[@]}" "$2"; }

dl "${TMP_DIR}/${ASSET}"          "${DOWNLOAD_URL}" || { set_status failed "download failed"; exit 1; }
dl "${TMP_DIR}/${ASSET}.sha256"   "${SHA_URL}"      || { set_status failed "sha256 download failed"; exit 1; }

# ── 校验 ───────────────────────────────────────
set_status verifying "Verifying sha256..."
cd "${TMP_DIR}"
sha256sum -c "${ASSET}.sha256" || { set_status failed "sha256 mismatch"; exit 1; }

# ── 解压 ───────────────────────────────────────
set_status installing "Extracting..."
rm -rf "${STAGING}"
mkdir -p "${STAGING}"
tar -xzf "${ASSET}" -C "${STAGING}"

RELEASE_BIN=$(ls "${STAGING}/bin/" | grep -v '\.' | head -1)
[[ -f "${STAGING}/bin/${RELEASE_BIN}" ]] || { set_status failed "corrupted package"; exit 1; }

# ── 停止 ───────────────────────────────────────
set_status stopping "Stopping service..."
systemctl stop "${SERVICE_NAME:-auth2api_ex-elixir}.service"
sleep 2

# ── 替换 ───────────────────────────────────────
set_status installing "Swapping release..."

[[ -d "${DEPLOY_DIR}/lib" ]] && {
  rm -rf "${PREVIOUS}"
  mkdir -p "${PREVIOUS}"
  for item in bin lib releases; do
    [[ -e "${DEPLOY_DIR}/${item}" ]] && mv "${DEPLOY_DIR}/${item}" "${PREVIOUS}/${item}"
  done
  for d in "${DEPLOY_DIR}"/erts-*; do
    [[ -e "${d}" ]] && mv "${d}" "${PREVIOUS}/"
  done
}

for item in bin lib releases; do
  mv "${STAGING}/${item}" "${DEPLOY_DIR}/${item}"
done
for d in "${STAGING}"/erts-*; do
  [[ -e "${d}" ]] && mv "${d}" "${DEPLOY_DIR}/"
done

# ── 启动 ───────────────────────────────────────
set_status starting "Starting service..."
systemctl start "${SERVICE_NAME:-auth2api_ex-elixir}.service"

# ── 健康检查 ───────────────────────────────────
set_status health_checking "Checking health..."
sleep 3

for i in $(seq 1 10); do
  if curl -fsS "${HEALTH_URL}" >/dev/null 2>&1; then
    set_status done "Upgraded to ${TO_VERSION}"
    rm -rf "${TMP_DIR}" "${STAGING}"
    exit 0
  fi
  sleep 2
done

# ── 回滚 ───────────────────────────────────────
set_status rolling_back "Health check failed, rolling back..."

systemctl stop "${SERVICE_NAME:-auth2api_ex-elixir}.service"
sleep 2

rm -rf "${DEPLOY_DIR}/bin" "${DEPLOY_DIR}/lib" "${DEPLOY_DIR}/releases"
rm -rf "${DEPLOY_DIR}"/erts-*

for item in bin lib releases; do
  [[ -e "${PREVIOUS}/${item}" ]] && mv "${PREVIOUS}/${item}" "${DEPLOY_DIR}/${item}"
done
for d in "${PREVIOUS}"/erts-*; do
  [[ -e "${d}" ]] && mv "${d}" "${DEPLOY_DIR}/"
done

systemctl start "${SERVICE_NAME:-auth2api_ex-elixir}.service"
set_status rolled_back "Rollback complete"
rm -rf "${TMP_DIR}" "${STAGING}"
exit 1
UPDEOF

chmod +x "${BIN_DIR}/auth2api_ex-updater"
$SUDO chown root:root "${BIN_DIR}/auth2api_ex-updater" 2>/dev/null || true
ok "updater: ${BIN_DIR}/auth2api_ex-updater"

# ── systemd updater 服务 ────────────────────────────────────
$SUDO tee "/etc/systemd/system/${UPDATER_SERVICE}.service" > /dev/null <<UPDEOF
[Unit]
Description=auth2api_ex auto updater
After=network.target

[Service]
Type=oneshot
User=root
EnvironmentFile=-${ENV_FILE}
ExecStart=${BIN_DIR}/auth2api_ex-updater
StandardOutput=journal
StandardError=journal
UPDEOF

ok "${UPDATER_SERVICE}.service"

# ── sudoers ──────────────────────────────────────────────────
if [[ "$(id -u)" -ne 0 ]]; then
  SUDOERS_LINE="$(whoami) ALL=(root) NOPASSWD: /bin/systemctl start ${UPDATER_SERVICE}.service"
  if ! $SUDO grep -qF "${SUDOERS_LINE}" /etc/sudoers /etc/sudoers.d/* 2>/dev/null; then
    echo "${SUDOERS_LINE}" | $SUDO tee "/etc/sudoers.d/${NAME:-auth2api_ex}-updater" > /dev/null
    $SUDO chmod 440 "/etc/sudoers.d/${NAME:-auth2api_ex}-updater"
    ok "sudoers 已配置"
  fi
fi

# ── 启动服务 ────────────────────────────────────────────────
log "启动服务..."
$SUDO systemctl daemon-reload
$SUDO systemctl enable "${SERVICE_NAME}"
$SUDO systemctl start "${SERVICE_NAME}"
sleep 2

# ── 健康检查 ────────────────────────────────────────────────
log "健康检查..."
if curl -fsS "http://127.0.0.1:${SERVICE_PORT}/admin/api/version" >/dev/null 2>&1; then
  ok "服务启动成功"
else
  warn "健康检查未通过，查看日志: sudo journalctl -u ${SERVICE_NAME} -n 50"
fi

# ── 完成 ────────────────────────────────────────────────────
echo ""
echo "  ┌─────────────────────────────────────┐"
echo "  │  auth2api_ex-elixir ${TAG} 部署完成    │"
echo "  └─────────────────────────────────────┘"
echo ""
echo "  安装目录 : ${DEPLOY_DIR}"
echo "  配置文件 : ${CONFIG_YAML}"
echo "  OAuth 数据: ${AUTH_DIR}"
echo ""
echo "  状态: sudo systemctl status ${SERVICE_NAME}"
echo "  日志: sudo journalctl -u ${SERVICE_NAME} -f"
echo "  管理: http://127.0.0.1:${SERVICE_PORT}/admin"
echo ""
echo "  ⚠ 请修改 ${CONFIG_YAML} 中的 admin 密码和 api-keys"
echo ""
