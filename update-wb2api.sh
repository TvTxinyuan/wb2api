#!/usr/bin/env bash
# =============================================================================
# wb2api 升级：git pull + 重新构建 + 重启 + 健康检查
#   bash /opt/wb2api/update-wb2api.sh
#   WB2API_REF=master bash /opt/wb2api/update-wb2api.sh
# 数据在 Docker 卷 admin_data 里，重建容器不会丢。
# =============================================================================
set -Eeuo pipefail
WB2API_DIR="${WB2API_DIR:-/opt/wb2api}"
WB2API_REF="${WB2API_REF:-master}"
PIP_INDEX="${PIP_INDEX:-https://pypi.tuna.tsinghua.edu.cn/simple}"
ENV_FILE="$WB2API_DIR/.env.docker"

[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行：sudo bash $0"; exit 1; }
[ -f "$ENV_FILE" ] || { echo "找不到 $ENV_FILE，先执行安装脚本"; exit 1; }
WB2API_PORT=$(awk -F= '/^ADMIN_PORT=/ { print $2 }' "$ENV_FILE")
WB2API_PORT=${WB2API_PORT:-8790}

cd "$WB2API_DIR"
echo "[1/3] 拉取最新代码"
git fetch --depth 1 origin "$WB2API_REF" && git reset --hard "origin/$WB2API_REF"

echo "[2/3] 重新构建镜像"
docker compose --env-file "$ENV_FILE" build --build-arg "PIP_INDEX_URL=$PIP_INDEX" admin \
  || docker compose --env-file "$ENV_FILE" build --build-arg "PIP_INDEX_URL=https://pypi.org/simple" admin

echo "[3/3] 重启并做健康检查"
docker compose --env-file "$ENV_FILE" up -d admin
for _ in $(seq 1 60); do
  if curl -fsS -m 3 "http://127.0.0.1:${WB2API_PORT}/api/app/version" >/dev/null 2>&1; then
    echo "升级完成，服务正常。当前版本：$(curl -fsS "http://127.0.0.1:${WB2API_PORT}/api/app/version")"
    exit 0
  fi
  sleep 2
done
echo "服务未响应，最近日志：" >&2
docker compose --env-file "$ENV_FILE" logs --tail=60 admin >&2
exit 1
