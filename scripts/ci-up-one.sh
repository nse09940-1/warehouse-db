#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

require_env POSTGRES_USER POSTGRES_PASSWORD TEST_DB_NAME POSTGRES_EXPORTER_USER POSTGRES_EXPORTER_PASSWORD

current_migration="${1:-}"
if [[ -z "${current_migration}" ]]; then
  echo "Usage: ci-up-one.sh <current_migration_path>" >&2
  exit 1
fi

version="$(extract_version_from_file "${current_migration}")"
relative_migration="${current_migration#${WORKSPACE_DIR}/}"

echo "Seqwall up: ${current_migration}"
liquibase_for_db "${TEST_DB_NAME}" \
  --changelog-file="${relative_migration}" \
  update
