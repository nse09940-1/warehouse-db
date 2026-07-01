#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

require_env POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD

if ! psql_for_db "${POSTGRES_DB}" -tAc \
  "SELECT 1 FROM pg_matviews WHERE matviewname = 'mv_revenue_by_day_category' LIMIT 1;" \
  | grep -q "1"; then
  echo "Materialized view mv_revenue_by_day_category does not exist. Skipping refresh."
  exit 0
fi

echo "Refreshing mv_revenue_by_day_category (CONCURRENTLY)"
psql_for_db "${POSTGRES_DB}" -v ON_ERROR_STOP=1 -c \
  "REFRESH MATERIALIZED VIEW CONCURRENTLY mv_revenue_by_day_category;"

echo "Refresh completed."
