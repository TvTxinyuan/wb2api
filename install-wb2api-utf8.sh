#!/usr/bin/env bash
# =============================================================================
# wb2api 一键部署（Ubuntu 22.04 / 24.04，Docker 方式）
#
#   GitHub: https://github.com/xiaofan6ya/wb2api  （原 workbuddy2api 已改名）
#
# 做什么：
#   1. 检查系统与内存（2G 机器没问题，但会加/检查 swap 和磁盘空间）
#   2. 安装 Docker Engine + compose 插件（用腾讯云内网镜像，再退回官方/国内源）
#   3. 写国内镜像加速配置（腾讯云内网 + 通用镜像）
#   4. 从 GitHub（失败自动用 ghproxy 镜像）拉取 wb2api 源码
#   5. 生成 .env.docker：随机强密码 + 随机 JWT 密钥，数据库用 SQLite（无需 MySQL/Redis）
#   6. 构建并启动 admin 容器（端口 127.0.0.1:8790，只对本机开放）
#   7. 自检 + 打印后台地址、账号、密码
#
# 安全设计：
#   * 容器端口只映射到 127.0.0.1，公网访问不到；你从 Windows 用 SSH 隧道打开
#   * 工作目录 700 权限，.env.docker 600 权限（里面有后台密码）
#   * 单 worker、内存不设硬限制（2G 机器别设太小，否则构建/启动可能被杀）
#
# 用法（root 执行）：
#   bash install-wb2api.sh
#   WB2API_REF=master         bash install-wb2api.sh     # 固定分支
#   WB2API_DIR=/opt/wb2api    bash install-wb2api.sh     # 改安装目录
#   WB2API_BIND=0.0.0.0       bash install-wb2api.sh     # 直接对公网开放（不推荐）
# =============================================================================
set -Eeuo pipefail

# ------------------------------ 可调参数 -------------------------------------
WB2API_DIR="${WB2API_DIR:-/opt/wb2api}"
WB2API_REPO="${WB2API_REPO:-https://github.com/xiaofan6ya/wb2api.git}"
WB2API_REF="${WB2API_REF:-master}"
WB2API_BIND="${WB2API_BIND:-127.0.0.1}"   # 想公网直连改成 0.0.0.0，然后放行 8790
WB2API_PORT="${WB2API_PORT:-8790}"
ADMIN_USER="${ADMIN_USER:-admin}"
PIP_INDEX="${PIP_INDEX:-https://pypi.tuna.tsinghua.edu.cn/simple}"
DEPLOY_LOG=/var/log/wb2api-deploy.log
# -----------------------------------------------------------------------------

if [ -t 1 ]; then
  R=$'\033[0m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYA=$'\033[36m'; BLD=$'\033[1m'
else
  R=''; RED=''; GRN=''; YEL=''; CYA=''; BLD=''
fi
TOTAL=7; N=0
step() { N=$((N + 1)); printf '\n%s==> [%s/%s] %s%s\n' "$BLD$CYA" "$N" "$TOTAL" "$*" "$R"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '%s[OK]%s %s\n' "$GRN" "$R" "$*"; }
warn() { printf '%s[注意]%s %s\n' "$YEL" "$R" "$*"; }
die()  { printf '\n%s[失败]%s %s\n' "$RED" "$R" "$*" >&2; exit 1; }
trap 'printf "\n%s[失败]%s 第 %s 行：%s\n" "$RED" "$R" "$LINENO" "$BASH_COMMAND" >&2' ERR

[ "$(id -u)" -eq 0 ] || die "请用 root 运行：sudo bash $0"
export DEBIAN_FRONTEND=noninteractive
: >"$DEPLOY_LOG"

# ---------------------------- 1. 环境检查 ------------------------------------
step "检查系统环境"
if [ -r /etc/os-release ]; then . /etc/os-release; fi
[ "${ID:-}" = ubuntu ] || warn "当前系统是 ${ID:-未知}，脚本按 Ubuntu 写的"
ok "系统：${PRETTY_NAME:-Ubuntu}"

MEM_MB=$(awk '/MemTotal/ { printf "%d", $2 / 1024 }' /proc/meminfo)
FREE_DISK_GB=$(( $(df -Pm / | awk 'NR == 2 { print $4 }') / 1024 ))
ok "内存 ${MEM_MB} MB，根分区剩余 ${FREE_DISK_GB} GB"
[ "$FREE_DISK_GB" -ge 6 ] || warn "磁盘剩余不足 6 GB，Docker 镜像构建可能失败（python:3.12-slim + 依赖约 1.5~2 GB）。"

if ! swapon --show=NAME --noheadings 2>/dev/null | grep -q .; then
  warn "没有 swap，创建 2 GB /swapfile（2G 内存构建镜像时更稳）"
  if [ ! -f /swapfile ]; then
    dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
    sysctl -qw vm.swappiness=20
  fi
fi
ok "swap：$(free -h | awk '/Swap:/ { print $2 }')"

# ---------------------------- 2. 安装 Docker ---------------------------------
step "安装 Docker Engine 与 compose 插件"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  ok "已安装：$(docker --version)，$(docker compose version --short 2>/dev/null || echo compose)"
else
  apt-get update -y >>"$DEPLOY_LOG" 2>&1
  apt-get install -y --no-install-recommends ca-certificates curl gnupg git openssl jq >>"$DEPLOY_LOG" 2>&1
  ok "已装基础工具（curl / git / openssl / jq）"

  # 轻量镜像常自带 docker 源，统一换成腾讯云（内网 3M 带宽下快很多），失败再退官方
  DOCKER_SOURCES=(
    "腾讯云内网|https://mirrors.cloud.tencent.com/docker-ce"
    "官方|https://download.docker.com/linux/ubuntu"
  )
  installed=0
  for entry in "${DOCKER_SOURCES[@]}"; do
    name=${entry%%|*}; base=${entry#*|}
    info "尝试 $name 源：$base"
    install -m 0755 -d /etc/apt/keyrings
    if curl -fsSL --connect-timeout 10 -m 60 "$base/linux/ubuntu/gpg" -o /tmp/docker.gpg \
       || curl -fsSL --connect-timeout 10 -m 60 "https://mirrors.cloud.tencent.com/docker-ce/linux/ubuntu/gpg" -o /tmp/docker.gpg; then
      gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg /tmp/docker.gpg 2>>"$DEPLOY_LOG"
      chmod a+r /etc/apt/keyrings/docker.gpg
      codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] ${base}/linux/ubuntu ${codename} stable" \
        >/etc/apt/sources.list.d/docker.list
      if apt-get update -y >>"$DEPLOY_LOG" 2>&1 \
         && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >>"$DEPLOY_LOG" 2>&1; then
        installed=1
        ok "Docker 已通过 $name 源安装"
        break
      fi
    fi
    rm -f /etc/apt/sources.list.d/docker.list
  done

  if [ "$installed" -ne 1 ]; then
    warn "Docker 源安装失败，退回 Ubuntu 自带 docker.io"
    apt-get install -y docker.io docker-compose-v2 >>"$DEPLOY_LOG" 2>&1 || apt-get install -y docker.io >>"$DEPLOY_LOG" 2>&1
  fi

  systemctl enable --now docker >>"$DEPLOY_LOG" 2>&1
  command -v docker >/dev/null 2>&1 || { tail -n 30 "$DEPLOY_LOG"; die "Docker 安装失败，请把 $DEPLOY_LOG 尾部发我"; }
  ok "$(docker --version)"
fi

systemctl is-active --quiet docker || systemctl start docker >>"$DEPLOY_LOG" 2>&1
ok "docker 服务：$(systemctl is-active docker)"
docker compose version >/dev/null 2>&1 || die "缺少 docker compose 插件（apt install docker-compose-plugin）"

# ---------------------------- 3. 镜像加速 ------------------------------------
step "配置镜像加速（拉 python 基础镜像用）"
mkdir -p /etc/docker
if [ ! -f /etc/docker/daemon.json ]; then
  cat >/etc/docker/daemon.json <<'JSON'
{
  "registry-mirrors": [
    "https://mirror.ccs.tencentyun.com",
    "https://docker.m.daocloud.io",
    "https://docker.1ms.run",
    "https://dockerproxy.net"
  ],
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
JSON
  systemctl restart docker >>"$DEPLOY_LOG" 2>&1
  ok "已写入 /etc/docker/daemon.json 并重启 docker"
else
  warn "/etc/docker/daemon.json 已存在，保持原样（如需加速请手动加 registry-mirrors）"
fi

# ---------------------------- 4. 拉取源码 ------------------------------------
step "获取 wb2api 源码"
apt-get install -y --no-install-recommends git >>"$DEPLOY_LOG" 2>&1 || true
umask 077
mkdir -p "$(dirname "$WB2API_DIR")"
chmod 700 "$(dirname "$WB2API_DIR")"

clone_ok=0
if [ -d "$WB2API_DIR/.git" ]; then
  info "目录已存在，尝试 git pull 更新"
  if git -C "$WB2API_DIR" pull --ff-only >>"$DEPLOY_LOG" 2>&1; then clone_ok=1; ok "已更新到最新代码"; fi
fi
if [ "$clone_ok" -ne 1 ]; then
  [ -e "$WB2API_DIR" ] && [ "$(ls -A "$WB2API_DIR" 2>/dev/null)" ] && die "$WB2API_DIR 已存在且不是 git 仓库，请先移走它或设置 WB2API_DIR=其他目录"
  for mirror in "" "https://ghfast.top/" "https://gh-proxy.com/" "https://ghproxy.net/"; do
    info "尝试：${mirror:-直连}${WB2API_REPO}"
    if git clone --depth 1 --branch "$WB2API_REF" "${mirror}${WB2API_REPO}" "$WB2API_DIR" >>"$DEPLOY_LOG" 2>&1; then
      clone_ok=1; break
    fi
    rm -rf "$WB2API_DIR"
  done
fi
[ "$clone_ok" -eq 1 ] || { tail -n 30 "$DEPLOY_LOG"; die "拉取 GitHub 源码失败（国内网络问题）。可换 WiFi/代理，或稍后重试"; }
chmod 700 "$WB2API_DIR"
ok "源码目录：$WB2API_DIR"

# ---------------------------- 5. 生成配置 ------------------------------------
step "生成 .env.docker（随机强密码，SQLite 数据库）"
ENV_FILE="$WB2API_DIR/.env.docker"
if [ -f "$ENV_FILE" ]; then
  warn ".env.docker 已存在，保留原有配置（如需重置请先备份后删除它）"
else
  ADMIN_PASSWORD=$(openssl rand -hex 12)
  ADMIN_JWT_SECRET=$(openssl rand -hex 32)
  cat >"$ENV_FILE" <<ENV
# wb2api 部署配置（由 install-wb2api.sh 生成，包含密码，请勿外传）
ADMIN_USERNAME=${ADMIN_USER}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
ADMIN_JWT_SECRET=${ADMIN_JWT_SECRET}
ADMIN_PORT=${WB2API_PORT}
ADMIN_DATABASE_URL=sqlite:////data/workbuddy.db
ADMIN_REDIS_URL=
ADMIN_GATEWAY_LIMIT_BACKEND=memory
TZ=Asia/Shanghai
ENV
  chmod 600 "$ENV_FILE"
  ok "已生成 $ENV_FILE（600 权限）"
fi
ADMIN_PASSWORD=$(awk -F= '/^ADMIN_PASSWORD=/ { print $2 }' "$ENV_FILE")
ADMIN_USER=$(awk -F= '/^ADMIN_USERNAME=/ { print $2 }' "$ENV_FILE")

# 单机 2G 内存：把端口绑定改成本机（或按需公网）
COMPOSE_OVERRIDE="$WB2API_DIR/docker-compose.override.yml"
cat >"$COMPOSE_OVERRIDE" <<OVR
services:
  admin:
    ports:
      - "${WB2API_BIND}:${WB2API_PORT}:8790"
OVR
chmod 600 "$COMPOSE_OVERRIDE"
ok "端口映射：${WB2API_BIND}:${WB2API_PORT} -> 容器 8790"

# ---------------------------- 6. 构建并启动 ----------------------------------
step "构建镜像并启动（首次要下载 pip 依赖，3M 带宽下 5～15 分钟）"
info "构建日志：$DEPLOY_LOG"
cd "$WB2API_DIR"
if ! tar_cmd=$(docker compose --env-file "$ENV_FILE" build --build-arg "PIP_INDEX_URL=$PIP_INDEX" admin 2>&1 | tee -a "$DEPLOY_LOG"); then
  warn "用清华 PyPI 源构建失败，改用官方 PyPI 重试……"
  docker compose --env-file "$ENV_FILE" build --build-arg "PIP_INDEX_URL=https://pypi.org/simple" admin >>"$DEPLOY_LOG" 2>&1 \
    || { tail -n 40 "$DEPLOY_LOG"; die "镜像构建失败，把上面的日志结尾发我"; }
fi
ok "镜像构建完成"

docker compose --env-file "$ENV_FILE" up -d admin >>"$DEPLOY_LOG" 2>&1
info "等待服务就绪……"
ready=0
for _ in $(seq 1 60); do
  if curl -fsS -m 3 "http://127.0.0.1:${WB2API_PORT}/api/app/version" >/dev/null 2>&1; then ready=1; break; fi
  sleep 2
done
[ "$ready" -eq 1 ] || { docker compose --env-file "$ENV_FILE" logs --tail=60 admin >&2; die "服务没起来，见上面日志"; }
ok "wb2api 已运行并响应健康检查"

# ---------------------------- 7. 自检 ----------------------------------------
step "自检"
docker compose --env-file "$ENV_FILE" ps
info "内存占用：$(free -h | awk '/Mem:/ { print $3 " / " $2 }')"
info "磁盘：$(df -h / | awk 'NR == 2 { print $4 " 可用" }')"

cat <<SUMMARY

$(printf '%s' "$BLD$GRN")================== wb2api 安装完成 ==================$(printf '%s' "$R")

  后台地址（服务器内部）：http://127.0.0.1:${WB2API_PORT}/admin
  登录账号：${ADMIN_USER}
  登录密码：${ADMIN_PASSWORD}

  ⚠ 上面密码也保存在：${ENV_FILE}
    （该文件 600 权限，查看： cat ${ENV_FILE}）

  这个端口只监听 ${WB2API_BIND}，公网访问不到。在你 Windows 电脑上运行：
      dsh-tunnel.bat 你的服务器公网IP   （只转发 DSH 的 3080）

  想在浏览器里同时打开 wb2api，请用下面这条隧道命令（另开一个 PowerShell 窗口）：
      ssh -N -L 127.0.0.1:${WB2API_PORT}:127.0.0.1:${WB2API_PORT} root@你的服务器公网IP
  然后浏览器访问 http://127.0.0.1:${WB2API_PORT}/admin

  常用命令：
    cd ${WB2API_DIR}
    docker compose --env-file .env.docker ps            # 状态
    docker compose --env-file .env.docker logs -f admin # 实时日志（Ctrl+C 退出）
    docker compose --env-file .env.docker restart admin # 重启
    bash ${WB2API_DIR}/update-wb2api.sh                 # 升级（git pull 后重建）

  数据备份（SQLite 在 Docker 卷 admin_data 里）：
    cd ${WB2API_DIR} && bash backup-wb2api.sh

==========================================================================
SUMMARY
