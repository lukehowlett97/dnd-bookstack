#!/usr/bin/env bash
set -euo pipefail
if [ "${DEBUG:-0}" = "1" ]; then set -x; fi

# Resolve repo root:
# 1) If we're already in a git repo, use it.
# 2) Otherwise, prefer a known path.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  REPO_ROOT="$(git rev-parse --show-toplevel)"
else
  for d in \
    "/root/srv/projects/bookstack" \
    "/root/bookstack" \
    "$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; do
    if [ -f "$d/docker-compose.yml" ]; then REPO_ROOT="$d"; break; fi
  done
fi

if [ -z "${REPO_ROOT:-}" ]; then
  echo "Could not locate repo root" >&2
  exit 1
fi

cd "$REPO_ROOT"

# Find compose file explicitly and bind it to all commands
if [ -f "$REPO_ROOT/docker-compose.yml" ]; then
  COMPOSE_FILE_PATH="$REPO_ROOT/docker-compose.yml"
elif [ -f "$REPO_ROOT/compose.yml" ]; then
  COMPOSE_FILE_PATH="$REPO_ROOT/compose.yml"
elif [ -f "$REPO_ROOT/compose.yaml" ]; then
  COMPOSE_FILE_PATH="$REPO_ROOT/compose.yaml"
else
  echo "No compose file found in $REPO_ROOT" >&2
  exit 1
fi

# Determine docker compose command (after COMPOSE_FILE_PATH is set)
if docker compose version >/dev/null 2>&1; then
  DC=(docker compose -f "$COMPOSE_FILE_PATH")
elif command -v docker-compose >/dev/null 2>&1; then
  DC=(docker-compose -f "$COMPOSE_FILE_PATH")
else
  echo "docker compose/docker-compose not found" >&2
  exit 1
fi

[ "${DEBUG:-0}" = "1" ] && echo "Using compose file: $COMPOSE_FILE_PATH; REPO_ROOT=$REPO_ROOT; DC=${DC[*]}" >&2

# Detect DB service name
DB_SERVICE="bookstack_db"
if ! "${DC[@]}" ps --services >/dev/null 2>&1; then
  # Older docker-compose may not support --services; fall back to ps output
  SERVICES=$("${DC[@]}" ps | awk 'NR>1{print $1}')
else
  SERVICES=$("${DC[@]}" ps --services)
fi
if ! printf '%s\n' "$SERVICES" | grep -qx "$DB_SERVICE"; then
  for candidate in db database mariadb mysql; do
    if printf '%s\n' "$SERVICES" | grep -qx "$candidate"; then DB_SERVICE="$candidate"; break; fi
  done
fi

# Ensure DB container is up
if ! "${DC[@]}" ps | grep -q "\b${DB_SERVICE}\b"; then
  echo "${DB_SERVICE} is not running; start your stack (e.g., '${DC[*]} up -d')" >&2
  exit 1
fi

# Create a fresh DB dump in-repo before committing
TS=$(date +%F_%H-%M-%S)
DB_DIR="${REPO_ROOT}/db_dumps"
mkdir -p "$DB_DIR"

# Try app user first, then root; prefer mariadb-dump, fallback to mysqldump inside the container
if "${DC[@]}" exec -T "$DB_SERVICE" sh -lc '
  set -e
  DUMP_BIN="$(command -v mariadb-dump || command -v mysqldump || true)"
  if [ -z "$DUMP_BIN" ]; then echo "No dump binary (mariadb-dump/mysqldump) in container" >&2; exit 127; fi
  exec "$DUMP_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"
' | gzip -9 > "${DB_DIR}/db_${TS}.sql.gz"; then
  :
else
  "${DC[@]}" exec -T "$DB_SERVICE" sh -lc '
    set -e
    DUMP_BIN="$(command -v mariadb-dump || command -v mysqldump || true)"
    if [ -z "$DUMP_BIN" ]; then echo "No dump binary (mariadb-dump/mysqldump) in container" >&2; exit 127; fi
    exec "$DUMP_BIN" -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"
  ' | gzip -9 > "${DB_DIR}/db_${TS}.sql.gz"
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
