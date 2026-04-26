#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

require_env POSTGRES_USER POSTGRES_PASSWORD TEST_DB_NAME POSTGRES_EXPORTER_USER POSTGRES_EXPORTER_PASSWORD

current_migration="${1:-}"
if [[ -z "${current_migration}" ]]; then
  echo "Usage: ci-down-one.sh <current_migration_path>" >&2
  exit 1
fi

version="$(extract_version_from_file "${current_migration}")"
relative_migration="${current_migration#${WORKSPACE_DIR}/}"
rollback_count="$(
  rg -c '^--changeset ' "${current_migration}" 2>/dev/null \
    || grep -c '^--changeset ' "${current_migration}"
)"

if [[ ! "${rollback_count}" =~ ^[0-9]+$ ]] || (( rollback_count < 1 )); then
  echo "Unable to determine rollback count for ${current_migration}" >&2
  exit 1
fi

echo "Seqwall down: ${current_migration} -> rollback-count ${rollback_count}"
liquibase_for_db "${TEST_DB_NAME}" \
  --changelog-file="${relative_migration}" \
  rollback-count "${rollback_count}"
