#!/usr/bin/env bash
set -euo pipefail

# Resolve repo root (one directory up from scripts/)
REPO_ROOT="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Create a fresh DB dump in-repo before committing
TS=$(date +%F_%H-%M-%S)
DB_DIR="${REPO_ROOT}/db_dumps"
mkdir -p "$DB_DIR"

# Try app user first, then root
if docker compose exec -T bookstack_db sh -c 'mysqldump -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"' | gzip -9 > "${DB_DIR}/db_${TS}.sql.gz"; then
  :
else
  docker compose exec -T bookstack_db sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"' | gzip -9 > "${DB_DIR}/db_${TS}.sql.gz"
fi

# Retention: keep last 30 dumps by mtime
ls -1t "$DB_DIR"/db_*.sql.gz 2>/dev/null | awk 'NR>30' | xargs -r rm -f || true

# Ensure local committer identity exists (repo-scoped)
if ! git config user.name >/dev/null; then
  git config user.name "BookStack Auto Backup"
fi
if ! git config user.email >/dev/null; then
  git config user.email "bookstack-auto@localhost"
fi

# Ensure a remote is configured
if ! git remote get-url origin >/dev/null 2>&1; then
  echo "No 'origin' remote configured; skipping push." >&2
  exit 0
fi

# Stage changes, commit if needed
git add -A
if [ -z "$(git status --porcelain)" ]; then
  echo "No changes to commit."
  exit 0
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
MSG="chore(backup): auto snapshot $(date -Iseconds)"
git commit -m "$MSG"

# Rebase on remote then push; tolerate failure if first push/auth missing
git pull --rebase origin "$BRANCH" || true
git push origin "$BRANCH"
echo "Pushed $BRANCH at $(date -Iseconds)"
