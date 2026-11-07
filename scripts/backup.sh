#!/usr/bin/env bash
# Usage: backup.sh <backup-dir> [keep-count]
# Dumps the Docmost PostgreSQL database and the file-storage volume.
# Honors DOCKER_HOST, so it also works against a remote Docker host
# (the backup files land on the machine running this script).
set -euo pipefail

BACKUP_DIR="${1:?backup dir required}"
KEEP="${2:-7}"
PROJECT="${COMPOSE_PROJECT_NAME:-docmost}"
STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
umask 077

if [ -z "$(docker compose ps -q db 2>/dev/null)" ]; then
  echo "No running db container for project '$PROJECT' - skipping backup (first deploy?)"
  exit 0
fi

echo "Dumping database..."
docker compose exec -T db sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists' \
  | gzip > "$BACKUP_DIR/docmost-db-$STAMP.sql.gz"

echo "Archiving file storage volume..."
docker run --rm -v "${PROJECT}_docmost_data:/data:ro" alpine:3.20 \
  tar -C /data -czf - . > "$BACKUP_DIR/docmost-storage-$STAMP.tar.gz"

# Retention: keep the newest $KEEP backups of each kind
for kind in db storage; do
  find "$BACKUP_DIR" -maxdepth 1 -name "docmost-$kind-*.gz" -printf '%T@ %p\n' \
    | sort -rn | tail -n +"$((KEEP + 1))" | cut -d' ' -f2- \
    | xargs -r -d '\n' rm -f --
done

echo "Backup written to $BACKUP_DIR (stamp $STAMP)"
