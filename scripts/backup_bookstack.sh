#!/usr/bin/env bash
set -euo pipefail

# Resolve repo root (one directory up from scripts/)
REPO_ROOT="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TS=$(date +%F_%H-%M-%S)
BASE="$REPO_ROOT/backups"
mkdir -p "$BASE"

# Dump DB using app user, fallback to root
if docker compose exec -T bookstack_db sh -c 'mysqldump -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"' | gzip -9 > "$BASE/db_${TS}.sql.gz"; then
  :
else
  docker compose exec -T bookstack_db sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"' | gzip -9 > "$BASE/db_${TS}.sql.gz"
fi

# Archive bind-mount data & key configs (ignore failures if folders missing)
tar -C "$REPO_ROOT" -czf "$BASE/files_${TS}.tar.gz" uploads storage theme docker-compose.yml .env || true

# Optional: copy nginx site file if present on host (when run as root)
if [ -f /etc/nginx/sites-available/bookstack ]; then
  cp -a /etc/nginx/sites-available/bookstack "$BASE/nginx_site_${TS}.conf"
fi

# Retention: 14 days
find "$BASE" -type f -name 'db_*.sql.gz' -mtime +14 -delete || true
find "$BASE" -type f -name 'files_*.tar.gz' -mtime +14 -delete || true

echo "Backup completed at $TS"
