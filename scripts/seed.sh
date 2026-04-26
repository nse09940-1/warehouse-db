#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

require_env POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD APP_ENV

if [[ ! "${APP_ENV}" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "APP_ENV contains unsupported characters: ${APP_ENV}" >&2
  exit 1
fi

if [[ "${APP_ENV,,}" == "prod" ]]; then
  echo "APP_ENV=prod. Seeding is skipped."
  exit 0
fi

seed_count="${SEED_COUNT:-10}"
if [[ ! "${seed_count}" =~ ^[0-9]+$ ]] || (( seed_count < 1 )); then
  echo "SEED_COUNT must be a positive integer. Current: ${seed_count}" >&2
  exit 1
fi

target_tag="$(normalize_version_to_tag "${MIGRATION_TARGET_TAG:-}")"
if [[ -n "${target_tag}" ]]; then
  target_version="${target_tag#v}"
else
  target_version="$(latest_seed_version)"
fi

if [[ -z "${target_version}" ]]; then
  echo "No seed files found. Skipping."
  exit 0
fi

echo "Applying seed files up to version ${target_version} with SEED_COUNT=${seed_count}"
app_env_sql="$(sql_escape_literal "${APP_ENV}")"

psql_for_db "${POSTGRES_DB}" -v ON_ERROR_STOP=1 -c "
CREATE TABLE IF NOT EXISTS seed_history (
  seed_version integer PRIMARY KEY,
  seed_count integer NOT NULL,
  app_env text NOT NULL,
  applied_at timestamptz NOT NULL DEFAULT now()
);"

while IFS= read -r seed_file; do
  seed_name="$(basename "${seed_file}")"
  seed_version="${seed_name%%_*}"
  seed_applied="$(
    psql_for_db "${POSTGRES_DB}" -tAc "SELECT 1 FROM seed_history WHERE seed_version = ${seed_version} LIMIT 1;"
  )"

  if (( 10#${seed_version} > 10#${target_version} )); then
    continue
  fi

  if [[ "${seed_applied}" == "1" ]]; then
    echo "Skipping ${seed_name}: already recorded in seed_history"
    continue
  fi

  echo "Running ${seed_name}"
  psql_for_db "${POSTGRES_DB}" \
    -v ON_ERROR_STOP=1 \
    -v seed_count="${seed_count}" \
    -f "${seed_file}"

  psql_for_db "${POSTGRES_DB}" \
    -v ON_ERROR_STOP=1 \
    -c "INSERT INTO seed_history (seed_version, seed_count, app_env, applied_at)
        VALUES (${seed_version}, ${seed_count}, '${app_env_sql}', now())
        ON CONFLICT (seed_version)
        DO UPDATE SET seed_count = EXCLUDED.seed_count, app_env = EXCLUDED.app_env, applied_at = EXCLUDED.applied_at;"
done < <(
  find "${WORKSPACE_DIR}/seeds" -maxdepth 1 -type f -name '[0-9][0-9][0-9]_seed.sql' | sort
)

echo "Seeding finished."
