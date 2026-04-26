#!/usr/bin/env bash
set -euo pipefail

require_env() {
  local key
  for key in "$@"; do
    if [[ -z "${!key:-}" ]]; then
      echo "Environment variable is required: ${key}" >&2
      exit 1
    fi
  done
}

require_env \
  POSTGRES_HOST \
  POSTGRES_DB \
  POSTGRES_USER \
  POSTGRES_PASSWORD \
  MINIO_ENDPOINT \
  MINIO_BACKUP_USER \
  MINIO_BACKUP_PASSWORD \
  BUCKET_BACKUP_NAME \
  BACKUP_RETENTION_COUNT \
  BACKUP_INTERVAL

if [[ ! "${BACKUP_RETENTION_COUNT}" =~ ^[0-9]+$ ]] || (( BACKUP_RETENTION_COUNT < 1 )); then
  echo "BACKUP_RETENTION_COUNT must be a positive integer. Current: ${BACKUP_RETENTION_COUNT}" >&2
  exit 1
fi

cron_file="/tmp/backup.crontab"
printf '%s %s\n' "${BACKUP_INTERVAL}" "/usr/local/bin/backup-once.sh" >"${cron_file}"

echo "Backup scheduler started. Cron=${BACKUP_INTERVAL}, retention=${BACKUP_RETENTION_COUNT}"
exec /usr/local/bin/supercronic "${cron_file}"
