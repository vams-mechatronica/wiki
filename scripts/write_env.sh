#!/usr/bin/env bash
# Writes the .env that docker compose reads, from environment variables
# (Jenkins job parameters + credentials). Usage: write_env.sh [output-file]
#
# - Every value is single-quoted, so compose takes it literally: a secret
#   containing $ is not interpolated. A value containing a single quote or a
#   newline can't be represented that way and is rejected.
# - The DB password is also written URL-encoded (POSTGRES_PASSWORD_URLENCODED)
#   for DATABASE_URL: characters such as @ : / # ? % in a raw password make
#   Docmost reject the URL ("DATABASE_URL must be a valid postgres connection
#   string") and crash-loop.
set -euo pipefail
export LC_ALL=C   # byte-wise string handling in urlencode

OUT="${1:-.env}"

urlencode() {
  local s="$1" out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}

# name=value line, single-quoted; refuses values compose can't take literally.
line() {
  local name="$1" value="$2"
  case "$value" in
    *"'"* | *$'\n'*)
      echo "ERROR: $name contains a single quote or newline, which .env can't hold literally. Use a different value." >&2
      exit 1 ;;
  esac
  printf "%s='%s'\n" "$name" "$value"
}

: "${APP_SECRET:?APP_SECRET is required}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
if [ "${#APP_SECRET}" -lt 32 ]; then
  echo "ERROR: APP_SECRET must be at least 32 characters (generate with: openssl rand -hex 32)." >&2
  exit 1
fi

umask 077
{
  line COMPOSE_PROJECT_NAME "${COMPOSE_PROJECT_NAME:-docmost}"
  line DOCMOST_VERSION "${DOCMOST_VERSION:-latest}"
  line APP_URL "${APP_URL:?APP_URL is required}"
  line DOCMOST_PORT "${DOCMOST_PORT:-3000}"
  line APP_SECRET "$APP_SECRET"
  line POSTGRES_DB "${POSTGRES_DB:-docmost}"
  line POSTGRES_USER "${POSTGRES_USER:-docmost}"
  line POSTGRES_PASSWORD "$POSTGRES_PASSWORD"
  line POSTGRES_PASSWORD_URLENCODED "$(urlencode "$POSTGRES_PASSWORD")"
  if [ "${ENABLE_SMTP:-false}" = "true" ]; then
    line MAIL_DRIVER smtp
    line MAIL_FROM_ADDRESS "${MAIL_FROM_ADDRESS:-}"
    line SMTP_HOST "${SMTP_HOST:-}"
    line SMTP_PORT "${SMTP_PORT:-587}"
    line SMTP_USERNAME "${SMTP_USERNAME:-}"
    line SMTP_PASSWORD "${SMTP_PASSWORD:-}"
  fi
} > "$OUT"

echo "Wrote $OUT"
