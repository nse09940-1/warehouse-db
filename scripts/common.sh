#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHANGELOG_FILE="liquibase.changelog.xml"

require_env() {
  local key
  for key in "$@"; do
    if [[ -z "${!key:-}" ]]; then
      echo "Environment variable is required: ${key}" >&2
      exit 1
    fi
  done
}

postgres_host() {
  echo "${POSTGRES_HOST:-postgres}"
}

postgres_url_for_db() {
  local db_name="${1}"
  echo "postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@$(postgres_host):5432/${db_name}?sslmode=disable"
}

sql_escape_literal() {
  local value="${1:-}"
  value="${value//\'/\'\'}"
  printf "%s" "${value}"
}

normalize_version_to_tag() {
  local raw="${1:-}"
  if [[ -z "${raw}" ]]; then
    echo ""
    return 0
  fi

  raw="${raw#v}"
  raw="${raw#V}"
  if [[ ! "${raw}" =~ ^[0-9]+$ ]]; then
    echo "Invalid version format: ${1}. Expected 001 or v001." >&2
    return 1
  fi

  printf "v%03d" "$((10#${raw}))"
}

extract_version_from_file() {
  local migration_file="${1:-}"
  local file_name
  file_name="$(basename "${migration_file}")"

  if [[ ! "${file_name}" =~ ^([0-9]{3})_.*\.sql$ ]]; then
    echo "Cannot extract migration version from file: ${migration_file}" >&2
    return 1
  fi

  echo "${BASH_REMATCH[1]}"
}

previous_tag() {
  local current_version="${1:-000}"
  local prev=$((10#${current_version} - 1))
  if (( prev < 0 )); then
    prev=0
  fi
  printf "v%03d" "${prev}"
}

latest_seed_version() {
  local latest
  latest="$(
    find "${WORKSPACE_DIR}/seeds" -maxdepth 1 -type f -name '[0-9][0-9][0-9]_seed.sql' \
      | sed -E 's#.*/([0-9]{3})_seed.sql#\1#' \
      | sort \
      | tail -n 1
  )"
  echo "${latest}"
}

liquibase_for_db() {
  local db_name="${1}"
  shift
  local java_opts="${JAVA_OPTS:-}"
  local changelog_file="${CHANGELOG_FILE}"
  local arg
  local -a liquibase_args=()

  for arg in "$@"; do
    case "${arg}" in
      --changelog-file=*)
        changelog_file="${arg#--changelog-file=}"
        ;;
      *)
        liquibase_args+=("${arg}")
        ;;
    esac
  done

  if [[ -n "${POSTGRES_EXPORTER_USER:-}" ]]; then
    java_opts="${java_opts} -DpostgresExporterUser=${POSTGRES_EXPORTER_USER}"
  fi

  if [[ -n "${POSTGRES_EXPORTER_PASSWORD:-}" ]]; then
    java_opts="${java_opts} -DpostgresExporterPassword=${POSTGRES_EXPORTER_PASSWORD}"
  fi

  if [[ -n "${DEBEZIUM_USER:-}" ]]; then
    java_opts="${java_opts} -DdebeziumUser=${DEBEZIUM_USER}"
  fi

  if [[ -n "${DEBEZIUM_PASSWORD:-}" ]]; then
    java_opts="${java_opts} -DdebeziumPassword=${DEBEZIUM_PASSWORD}"
  fi

  if [[ -n "${DEBEZIUM_PUBLICATION_NAME:-}" ]]; then
    java_opts="${java_opts} -DdebeziumPublicationName=${DEBEZIUM_PUBLICATION_NAME}"
  fi

  if [[ -n "${METABASE_DB_USER:-}" ]]; then
    java_opts="${java_opts} -DmetabaseDbUser=${METABASE_DB_USER}"
  fi

  if [[ -n "${METABASE_DB_PASSWORD:-}" ]]; then
    java_opts="${java_opts} -DmetabaseDbPassword=${METABASE_DB_PASSWORD}"
  fi

  JAVA_OPTS="${java_opts# }" liquibase \
    --changelog-file="${changelog_file}" \
    --search-path="${WORKSPACE_DIR}" \
    --url="jdbc:postgresql://$(postgres_host):5432/${db_name}" \
    --username="${POSTGRES_USER}" \
    --password="${POSTGRES_PASSWORD}" \
    --log-level=info \
    "${liquibase_args[@]}"
}

psql_for_db() {
  local db_name="${1}"
  shift

  PGPASSWORD="${POSTGRES_PASSWORD}" psql \
    -h "$(postgres_host)" \
    -p 5432 \
    -U "${POSTGRES_USER}" \
    -d "${db_name}" \
    "$@"
}
