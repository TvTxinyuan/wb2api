#!/usr/bin/env bash
# =============================================================================
# wb2api 备份：把 SQLite 数据库（Docker 卷 admin_data 里的 workbuddy.db）
# 与配置文件一起打包到 /opt/wb2api/backups/
#   bash /opt/wb2api/backup-wb2api.sh          # 备份
#   bash /opt/wb2api/backup-wb2api.sh --list   # 查看已有备份
# 注：备份里含账号凭证和后台密码，默认 600 权限，别外传。
# =============================================================================
set -Eeuo pipefail
WB2API_DIR="${WB2API_DIR:-/opt/wb2api}"
ENV_FILE="$WB2API_DIR/.env.docker"
BACKUP_DIR="$WB2API_DIR/backups"

[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行：sudo bash $0"; exit 1; }
mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"

if [ "${1:-}" = "--list" ]; then
  ls -lh "$BACKUP_DIR"
  exit 0
fi

[ -f "$ENV_FILE" ] || { echo "找不到 $ENV_FILE"; exit 1; }
STAMP=$(date +%Y%m%d-%H%M%S)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cd "$WB2API_DIR"
echo "停止 admin 容器（保证数据库一致性）……"
docker compose --env-file "$ENV_FILE" stop admin
docker compose --env-file "$ENV_FILE" cp admin:/data/. "$TMP/data/" || true
docker compose --env-file "$ENV_FILE" start admin
cp "$ENV_FILE" "$TMP/env.docker"

OUT="$BACKUP_DIR/wb2api-$STAMP.tar.gz"
tar -czf "$OUT" -C "$TMP" .
chmod 600 "$OUT"
echo "备份完成：$OUT （$(du -h "$OUT" | awk '{print $1}')）"
echo "恢复方法：docker compose stop admin; docker compose cp <解压目录>/data/. admin:/data/; docker compose start admin"
