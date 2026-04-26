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
  BUCKET_BACKUP_NAME

mc alias set backup "${MINIO_ENDPOINT}" "${MINIO_BACKUP_USER}" "${MINIO_BACKUP_PASSWORD}" >/dev/null

target_object="${1:-}"
if [[ -z "${target_object}" ]]; then
  mapfile -t object_names < <(
    mc ls --json "backup/${BUCKET_BACKUP_NAME}" \
      | jq -r --arg db "${POSTGRES_DB}" '
          select(.type == "file")
          | (.key // .name // empty)
          | select(test("^backup_" + $db + "_[0-9]{8}T[0-9]{6}Z\\.dump$"))
        ' \
      | sort
  )

  if (( ${#object_names[@]} == 0 )); then
    echo "No backup objects found for database ${POSTGRES_DB}" >&2
    exit 1
  fi

  target_object="${object_names[-1]}"
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT
restore_file="${work_dir}/restore.dump"

echo "Downloading backup: ${target_object}"
mc cp "backup/${BUCKET_BACKUP_NAME}/${target_object}" "${restore_file}" >/dev/null

echo "Restoring into database: ${POSTGRES_DB}"
PGPASSWORD="${POSTGRES_PASSWORD}" pg_restore \
  -h "${POSTGRES_HOST}" \
  -p 5432 \
  -U "${POSTGRES_USER}" \
  -d "${POSTGRES_DB}" \
  --clean \
  --if-exists \
  --no-owner \
  --no-privileges \
  "${restore_file}"

echo "Restore completed from ${target_object}"
