#!/bin/bash
# Debian 13 / 12 安装 Docker 和 Docker Compose
# 基于 ajeef 原脚本修改
# GitHub 下载加速：https://v4.gh-proxy.org
#
# 注意：
# 1. GitHub 代理只用于 Compose 下载。
# 2. Docker APT 仓库和 Docker Hub 镜像拉取仍使用官方地址。
# 3. 将用户加入 docker 组等同于授予高权限，仅添加可信用户。
# 4. 不自动删除已有 Docker、containerd 或容器数据。

set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    printf "${GREEN}[*]${NC} %s\n" "$*"
}

warn() {
    printf "${YELLOW}[!]${NC} %s\n" "$*" >&2
}

error() {
    printf "${RED}[X]${NC} %s\n" "$*" >&2
    exit 1
}

TMP_DIR=""
cleanup() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf -- "$TMP_DIR"
    fi
}
trap cleanup EXIT
trap 'printf "${RED}[X]${NC} 第 %s 行执行失败，请检查上方错误信息。\n" "$LINENO" >&2' ERR

# 可通过环境变量覆盖。
GH_PROXY="${GH_PROXY:-https://v4.gh-proxy.org}"
GH_PROXY="${GH_PROXY%/}"
DOCKER_USER="${DOCKER_USER:-${SUDO_USER:-}}"
RUN_TEST="${RUN_TEST:-1}"

[[ "$EUID" -eq 0 ]] || error "请以 root 运行：sudo bash install-docker.sh"
[[ -r /etc/os-release ]] || error "未找到 /etc/os-release。"

# shellcheck disable=SC1091
. /etc/os-release

[[ "${ID:-}" == "debian" ]] || error "此脚本仅支持 Debian，不自动配置其他发行版。"

case "${VERSION_ID:-}" in
    13) CODENAME="trixie" ;;
    12) CODENAME="bookworm" ;;
    *) error "此脚本仅支持 Debian 13 / 12，当前版本：${VERSION_ID:-未知}" ;;
esac

command -v systemctl >/dev/null 2>&1 \
    || error "未检测到 systemctl，请在使用 systemd 的 Debian 主机运行。"
[[ -d /run/systemd/system ]] \
    || error "当前环境没有运行 systemd，不适合执行此脚本。"

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
    amd64) COMPOSE_ARCH="x86_64" ;;
    arm64) COMPOSE_ARCH="aarch64" ;;
    armhf) COMPOSE_ARCH="armv7" ;;
    ppc64el) COMPOSE_ARCH="ppc64le" ;;
    *) error "此脚本未配置架构：$ARCH" ;;
esac

log "系统：Debian ${VERSION_ID}（${CODENAME}），架构：${ARCH}"

# 不擅自卸载可能被其他服务使用的软件包。
CONFLICTS=()
for pkg in docker.io docker-compose docker-doc docker-buildx \
           podman-docker containerd runc; do
    if [[ "$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)" \
          == "install ok installed" ]]; then
        CONFLICTS+=("$pkg")
    fi
done

if (( ${#CONFLICTS[@]} > 0 )); then
    error "发现可能冲突的软件包：${CONFLICTS[*]}。请先确认用途并手动处理，再运行脚本。"
fi

log "更新系统包列表..."
apt-get update

log "安装基础依赖..."
apt-get install -y ca-certificates curl

TMP_DIR="$(mktemp -d)"

log "下载 Docker 官方 GPG 密钥..."
install -m 0755 -d /etc/apt/keyrings
curl -fSL --retry 3 --connect-timeout 15 --max-time 120 \
    https://download.docker.com/linux/debian/gpg \
    -o "$TMP_DIR/docker.asc"
[[ -s "$TMP_DIR/docker.asc" ]] || error "Docker GPG 密钥下载为空。"
install -m 0644 "$TMP_DIR/docker.asc" /etc/apt/keyrings/docker.asc

# 备份本脚本涉及的同名源配置，再写入新配置。
# 其他文件中的 Docker 源不自动修改。
BACKUP_SUFFIX="$(date +%Y%m%d-%H%M%S).$$"
for source_file in \
    /etc/apt/sources.list.d/docker.list \
    /etc/apt/sources.list.d/docker.sources; do
    if [[ -e "$source_file" ]]; then
        log "备份已有源配置：${source_file}"
        mv -- "$source_file" "${source_file}.bak.${BACKUP_SUFFIX}"
    fi
done

log "配置 Docker 官方仓库：${CODENAME}"
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

log "更新 Docker 软件包索引..."
apt-get update

log "安装 Docker Engine 和 Buildx..."
apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin

log "启动 Docker 并设置开机自启..."
systemctl enable --now docker
systemctl is-active --quiet docker \
    || error "Docker 未能启动，请运行：journalctl -u docker -n 100 --no-pager"

command -v docker >/dev/null 2>&1 || error "未找到 docker 命令。"
docker info >/dev/null

# 保留原脚本 GitHub 下载 Compose 的方式，并增加代理。
# 使用全局插件目录，避免只对 root 用户生效。
COMPOSE_URL="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${COMPOSE_ARCH}"
COMPOSE_PROXY_URL="${GH_PROXY}/${COMPOSE_URL}"
COMPOSE_TMP="${TMP_DIR}/docker-compose"
COMPOSE_DIR="/usr/local/lib/docker/cli-plugins"

download_compose() {
    local url="$1"
    rm -f -- "$COMPOSE_TMP"

    if ! curl -fSL --retry 2 --connect-timeout 15 --max-time 300 \
        "$url" -o "$COMPOSE_TMP"; then
        return 1
    fi

    [[ -s "$COMPOSE_TMP" ]] || return 1

    # 基本格式检查：防止将代理错误页当作 Linux 可执行文件。
    local magic
    magic="$(od -An -tx1 -N4 "$COMPOSE_TMP" | tr -d ' \n')"
    [[ "$magic" == "7f454c46" ]] || return 1

    chmod 0755 "$COMPOSE_TMP"
    "$COMPOSE_TMP" version >/dev/null 2>&1 || return 1
}

log "通过 GitHub 加速地址下载 Compose..."
if ! download_compose "$COMPOSE_PROXY_URL"; then
    warn "代理下载或基本验证失败，尝试 GitHub 原地址..."
    download_compose "$COMPOSE_URL" \
        || error "Compose 下载失败，请检查网络或代理地址。"
fi

install -m 0755 -d "$COMPOSE_DIR"

if [[ -e "${COMPOSE_DIR}/docker-compose" ]]; then
    cp -a -- "${COMPOSE_DIR}/docker-compose" \
        "${COMPOSE_DIR}/docker-compose.bak.${BACKUP_SUFFIX}"
fi

install -m 0755 "$COMPOSE_TMP" "${COMPOSE_DIR}/docker-compose"

# 用户目录中的旧插件可能优先于全局插件。
if [[ -e "${HOME:-/root}/.docker/cli-plugins/docker-compose" ]]; then
    warn "当前用户目录存在旧 Compose 插件，可能覆盖刚安装的全局版本。"
    warn "请检查：${HOME:-/root}/.docker/cli-plugins/docker-compose"
fi

# 只处理 sudo 调用用户或显式指定用户，不猜测第一个普通用户。
if [[ -n "$DOCKER_USER" && "$DOCKER_USER" != "root" ]]; then
    if id "$DOCKER_USER" >/dev/null 2>&1; then
        warn "将可信用户 '${DOCKER_USER}' 加入 docker 组，该组拥有高权限。"
        usermod -aG docker "$DOCKER_USER"
        log "用户组变更需注销并重新登录后生效。"
    else
        warn "用户 '${DOCKER_USER}' 不存在，跳过用户组配置。"
    fi
else
    log "未指定非 root 用户，跳过 docker 组配置。"
fi

log "验证安装..."
docker --version
docker compose version

if [[ "$RUN_TEST" == "1" ]]; then
    log "运行 hello-world（Docker Hub 拉取不使用 GitHub 代理）..."
    if timeout 180 docker run --rm hello-world; then
        log "hello-world 测试通过。"
    else
        warn "hello-world 测试失败或超时，但 Docker 服务和 Compose 已验证。"
        warn "请检查 Docker Hub 网络访问，再执行：docker run --rm hello-world"
    fi
fi

printf "\n${GREEN}安装完成！${NC}\n"
log "Compose 全局安装目录：${COMPOSE_DIR}"
log "使用命令：docker compose"
log "本脚本没有修改 Docker Hub 镜像加速配置。"
