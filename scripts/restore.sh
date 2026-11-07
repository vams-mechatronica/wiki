#!/usr/bin/env bash
# Usage: restore.sh <db-dump.sql.gz> [storage.tar.gz]
# Restores a backup produced by backup.sh. Stops the app while restoring.
set -euo pipefail

DB_DUMP="${1:?db dump file required}"
STORAGE="${2:-}"
PROJECT="${COMPOSE_PROJECT_NAME:-docmost}"

docker compose stop docmost
docker compose up -d --wait db redis

echo "Restoring database from $DB_DUMP..."
gunzip -c "$DB_DUMP" \
  | docker compose exec -T db sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'

if [ -n "$STORAGE" ]; then
  echo "Restoring file storage from $STORAGE..."
  docker run --rm -i -v "${PROJECT}_docmost_data:/data" alpine:3.20 \
    sh -c 'find /data -mindepth 1 -delete && tar -C /data -xzf -' < "$STORAGE"
fi

docker compose up -d docmost
echo "Restore complete."
