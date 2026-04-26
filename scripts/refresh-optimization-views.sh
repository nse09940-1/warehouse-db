#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

require_env POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD

psql_for_db "${POSTGRES_DB}" -v ON_ERROR_STOP=1 -c "
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_revenue_by_day_category;
"

echo "Optimization materialized views refreshed."
