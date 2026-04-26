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
  BACKUP_RETENTION_COUNT

if [[ ! "${BACKUP_RETENTION_COUNT}" =~ ^[0-9]+$ ]] || (( BACKUP_RETENTION_COUNT < 1 )); then
  echo "BACKUP_RETENTION_COUNT must be a positive integer. Current: ${BACKUP_RETENTION_COUNT}" >&2
  exit 1
fi

backup_state_file="${BACKUP_STATE_FILE:-/backup-state/last-backup-state.json}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_file_name="backup_${POSTGRES_DB}_${timestamp}.dump"

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT
dump_path="${work_dir}/${backup_file_name}"

echo "Creating dump: ${backup_file_name}"
PGPASSWORD="${POSTGRES_PASSWORD}" pg_dump \
  -h "${POSTGRES_HOST}" \
  -p 5432 \
  -U "${POSTGRES_USER}" \
  -d "${POSTGRES_DB}" \
  -Fc \
  -f "${dump_path}"

echo "Uploading dump to bucket: ${BUCKET_BACKUP_NAME}"
mc alias set backup "${MINIO_ENDPOINT}" "${MINIO_BACKUP_USER}" "${MINIO_BACKUP_PASSWORD}" >/dev/null
mc cp "${dump_path}" "backup/${BUCKET_BACKUP_NAME}/${backup_file_name}" >/dev/null

list_json="${work_dir}/objects.jsonl"
mc ls --json "backup/${BUCKET_BACKUP_NAME}" >"${list_json}"

mapfile -t object_names < <(
  jq -r --arg db "${POSTGRES_DB}" '
    select(.type == "file")
    | (.key // .name // empty)
    | select(test("^backup_" + $db + "_[0-9]{8}T[0-9]{6}Z\\.dump$"))
  ' "${list_json}" \
  | sort
)

total_backups="${#object_names[@]}"
if (( total_backups > BACKUP_RETENTION_COUNT )); then
  delete_count=$((total_backups - BACKUP_RETENTION_COUNT))
  for ((idx = 0; idx < delete_count; idx++)); do
    old_object="${object_names[$idx]}"
    echo "Removing old backup: ${old_object}"
    mc rm "backup/${BUCKET_BACKUP_NAME}/${old_object}" >/dev/null
  done
fi

backup_size_bytes="$(stat -c%s "${dump_path}")"
backup_epoch="$(date -u +%s)"
state_tmp="${backup_state_file}.tmp"
mkdir -p "$(dirname "${backup_state_file}")"
cat >"${state_tmp}" <<EOF
{
  "db": "${POSTGRES_DB}",
  "bucket": "${BUCKET_BACKUP_NAME}",
  "object": "${backup_file_name}",
  "last_success_epoch": ${backup_epoch},
  "last_backup_size_bytes": ${backup_size_bytes}
}
EOF
mv -f "${state_tmp}" "${backup_state_file}"

echo "Backup completed: ${backup_file_name}, size=${backup_size_bytes} bytes"
