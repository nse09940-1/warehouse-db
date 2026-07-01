#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

require_env POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD TEST_DB_NAME APP_ENV POSTGRES_EXPORTER_USER POSTGRES_EXPORTER_PASSWORD DEBEZIUM_USER DEBEZIUM_PASSWORD DEBEZIUM_PUBLICATION_NAME METABASE_DB_NAME METABASE_DB_USER METABASE_DB_PASSWORD

if [[ ! "${TEST_DB_NAME}" =~ ^[A-Za-z0-9_]+$ ]]; then
  echo "TEST_DB_NAME contains unsupported characters: ${TEST_DB_NAME}" >&2
  exit 1
fi

if [[ ! "${METABASE_DB_NAME}" =~ ^[A-Za-z0-9_]+$ ]]; then
  echo "METABASE_DB_NAME contains unsupported characters: ${METABASE_DB_NAME}" >&2
  exit 1
fi

if [[ ! "${METABASE_DB_USER}" =~ ^[A-Za-z0-9_]+$ ]]; then
  echo "METABASE_DB_USER contains unsupported characters: ${METABASE_DB_USER}" >&2
  exit 1
fi

run_seqwall="${RUN_SEQWALL:-true}"
run_seqwall="${run_seqwall,,}"

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

echo "Waiting for writable primary..."
until psql_for_db "${POSTGRES_DB}" -tAc "SELECT CASE WHEN pg_is_in_recovery() THEN 0 ELSE 1 END;" | grep -q "1"; do
  sleep 2
done

echo "Recreating test database: ${TEST_DB_NAME}"
psql_for_db "postgres" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \"${TEST_DB_NAME}\" WITH (FORCE);"
psql_for_db "postgres" -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"${TEST_DB_NAME}\";"

case "${run_seqwall}" in
  false|0|no|off)
    echo "RUN_SEQWALL=${RUN_SEQWALL:-unset}. Seqwall staircase checks are skipped."
    ;;
  *)
    echo "Running Seqwall staircase checks"
    seqwall_postgres_url="$(postgres_url_for_db "${TEST_DB_NAME}")"
    seqwall staircase \
      --postgres-url "${seqwall_postgres_url}" \
      --upgrade "/bin/bash ${SCRIPT_DIR}/ci-up-one.sh {current_migration}" \
      --downgrade "/bin/bash ${SCRIPT_DIR}/ci-down-one.sh {current_migration}" \
      --migrations-path "${WORKSPACE_DIR}/migrations"
    ;;
esac

target_tag="$(normalize_version_to_tag "${MIGRATION_TARGET_TAG:-}")"
if [[ -n "${target_tag}" ]]; then
  target_version="${target_tag#v}"
  echo "Applying migrations up to version ${target_version} in ${POSTGRES_DB}"
  while IFS= read -r migration_file; do
    migration_name="$(basename "${migration_file}")"
    migration_version="${migration_name%%_*}"
    if (( 10#${migration_version} > 10#${target_version} )); then
      continue
    fi

    relative_migration="${migration_file#${WORKSPACE_DIR}/}"
    echo "Applying ${relative_migration}"
    liquibase_for_db "${POSTGRES_DB}" \
      --changelog-file="${relative_migration}" \
      update
  done < <(
    find "${WORKSPACE_DIR}/migrations" -maxdepth 1 -type f -name '[0-9][0-9][0-9]_*.sql' | sort
  )
else
  echo "Applying all migrations in ${POSTGRES_DB}"
  liquibase_for_db "${POSTGRES_DB}" update
fi

echo "Ensuring Metabase metadata database exists: ${METABASE_DB_NAME}"
metabase_db_exists="$(
  psql_for_db "postgres" -tAc "SELECT 1 FROM pg_database WHERE datname = '${METABASE_DB_NAME}' LIMIT 1;"
)"
if [[ "${metabase_db_exists}" != "1" ]]; then
  psql_for_db "postgres" -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"${METABASE_DB_NAME}\" OWNER \"${METABASE_DB_USER}\";"
fi

app_db_user="${APP_DB_USER:-${POSTGRES_USER}}"
if [[ "${app_db_user}" != "${POSTGRES_USER}" ]]; then
  echo "Granting privileges on ${POSTGRES_DB} objects to application role ${app_db_user}"
  psql_for_db "${POSTGRES_DB}" -v ON_ERROR_STOP=1 -v app_db_user="${app_db_user}" <<'SQL'
SELECT format('GRANT CONNECT, TEMP ON DATABASE %I TO %I', current_database(), :'app_db_user')\gexec
SELECT format('GRANT USAGE ON SCHEMA public TO %I', :'app_db_user')\gexec
SELECT format('GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON ALL TABLES IN SCHEMA public TO %I', :'app_db_user')\gexec
SELECT format('GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO %I', :'app_db_user')\gexec
SELECT format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO %I', :'app_db_user')\gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLES TO %I', :'app_db_user')\gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO %I', :'app_db_user')\gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO %I', :'app_db_user')\gexec
SQL
fi

if [[ "${APP_ENV,,}" == "prod" ]]; then
  echo "APP_ENV=prod. Seeding is skipped."
  exit 0
fi

echo "Running SQL seeders"
"${SCRIPT_DIR}/seed.sh"
