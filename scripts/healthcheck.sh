#!/usr/bin/env bash
# Usage: healthcheck.sh <base-url> [attempts] [sleep-seconds]
# Polls Docmost until it answers; exits non-zero (failing the build) if it never does.
set -euo pipefail

BASE_URL="${1:?base url required}"
ATTEMPTS="${2:-30}"
SLEEP="${3:-5}"
BASE_URL="${BASE_URL%/}"

for i in $(seq 1 "$ATTEMPTS"); do
  if curl -fsS -o /dev/null --max-time 5 "$BASE_URL/api/health" \
     || curl -fsS -o /dev/null --max-time 5 "$BASE_URL/"; then
    echo "Docmost is healthy at $BASE_URL (attempt $i)"
    exit 0
  fi
  echo "Waiting for Docmost at $BASE_URL ($i/$ATTEMPTS)..."
  sleep "$SLEEP"
done

echo "Docmost did not become healthy at $BASE_URL" >&2
exit 1
