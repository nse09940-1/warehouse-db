#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

require_env POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD TEST_DB_NAME APP_ENV POSTGRES_EXPORTER_USER POSTGRES_EXPORTER_PASSWORD

if [[ ! "${TEST_DB_NAME}" =~ ^[A-Za-z0-9_]+$ ]]; then
  echo "TEST_DB_NAME contains unsupported characters: ${TEST_DB_NAME}" >&2
  exit 1
fi

chmod +x \
  "${SCRIPT_DIR}/ci-up-one.sh" \
  "${SCRIPT_DIR}/ci-down-one.sh" \
  "${SCRIPT_DIR}/seed.sh"

echo "Waiting for PostgreSQL..."
until PGPASSWORD="${POSTGRES_PASSWORD}" pg_isready \
  -h "$(postgres_host)" \
  -p 5432 \
  -U "${POSTGRES_USER}" \
  -d "${POSTGRES_DB}" >/dev/null 2>&1; do
  sleep 2
done

echo "Recreating test database: ${TEST_DB_NAME}"
psql_for_db "postgres" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \"${TEST_DB_NAME}\" WITH (FORCE);"
psql_for_db "postgres" -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"${TEST_DB_NAME}\";"

echo "Running Seqwall staircase checks"
seqwall_postgres_url="$(postgres_url_for_db "${TEST_DB_NAME}")"
seqwall staircase \
  --postgres-url "${seqwall_postgres_url}" \
  --upgrade "/bin/bash ${SCRIPT_DIR}/ci-up-one.sh {current_migration}" \
  --downgrade "/bin/bash ${SCRIPT_DIR}/ci-down-one.sh {current_migration}" \
  --migrations-path "${WORKSPACE_DIR}/migrations"

target_tag="$(normalize_version_to_tag "${MIGRATION_TARGET_TAG:-}")"
if [[ -n "${target_tag}" ]]; then
  echo "Applying migrations up to tag ${target_tag} in ${POSTGRES_DB}"
  liquibase_for_db "${POSTGRES_DB}" update-to-tag --tag="${target_tag}"
else
  echo "Applying all migrations in ${POSTGRES_DB}"
  liquibase_for_db "${POSTGRES_DB}" update
fi

if [[ "${APP_ENV,,}" == "prod" ]]; then
  echo "APP_ENV=prod. Seeding is skipped."
  exit 0
fi

echo "Running SQL seeders"
"${SCRIPT_DIR}/seed.sh"
