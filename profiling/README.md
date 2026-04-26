# Profiling and Optimization Report

## Runbook

Baseline run from point 1:

```powershell
docker compose up -d --build --remove-orphans
docker compose --profile load run --rm k6
docker compose run --rm --entrypoint /bin/bash migrator /workspace/scripts/collect-profiling.sh
```

Degradation run from point 2:

```powershell
# Apply business schema changes without optimization migrations.
$env:MIGRATION_VERSION="010"
$env:SEED_COUNT="60000"
$env:K6_ORDER_COUNT="300000"
$env:K6_SUMMARY_EXPORT="/profiling/2/k6_summary.json"
$env:API_USE_REVENUE_MV="false"

docker compose up -d --build --remove-orphans
docker compose --profile load run --rm k6
docker compose run --rm --entrypoint /bin/bash -e PROFILE_DIR=profiling/2 migrator /workspace/scripts/collect-profiling.sh
```

If no endpoint has p95 growth above 30 percent versus point 1, rerun point 2 with:

```powershell
$env:SEED_COUNT="100000"
$env:K6_ORDER_COUNT="500000"
```

Final optimized run from point 3:

```powershell
# Apply all migrations including 011-013 and use the materialized view endpoint path.
$env:MIGRATION_VERSION=""
$env:API_USE_REVENUE_MV="true"
$env:K6_SUMMARY_EXPORT="/profiling/3/k6_summary.json"

docker compose up -d --build --remove-orphans
docker compose run --rm --entrypoint /bin/bash migrator /workspace/scripts/refresh-optimization-views.sh
docker compose run --rm k6 run --summary-export /profiling/3/k6_write_summary.json /scripts/k6_write_script.js
docker compose --profile load run --rm k6
docker compose run --rm --entrypoint /bin/bash -e PROFILE_DIR=profiling/3 migrator /workspace/scripts/collect-profiling.sh
```

## Observed Degradation

Point 2 uses `SEED_COUNT=60000` by default. Record the final value here after the actual run:

| Metric | Point 1 | Point 2 | Comment |
| --- | ---: | ---: | --- |
| SEED_COUNT | 60000 | 60000 | Increase point 2 to 100000 only if p95 growth is not visible. |
| customer_orders rows | TBD | TBD | Fill from `count(*)`. |
| customer_order_items rows | TBD | TBD | Fill from `count(*)`. |
| inventory_movements rows | TBD | TBD | Fill from `count(*)`. |
| customer_order_audit_notes rows | N/A | TBD | New append-heavy table from point 2. |

Queries with p95 growth above 30 percent:

| Query / Endpoint | p95 point 1 | p95 point 2 | Growth | Hypothesis based on EXPLAIN / pg_stat_statements |
| --- | ---: | ---: | ---: | --- |
| `GET /api/oltp/orders/{id}` | TBD | TBD | TBD | Expected degradation: `LEFT JOIN LATERAL` scans `customer_order_audit_notes` before migration 011 adds `(customer_order_id, created_at DESC)`. |
| `GET /api/olap/revenue-by-day` | TBD | TBD | TBD | Expected degradation: extra aggregation over `customer_order_audit_notes` plus larger `customer_order_items` range increases shared reads and execution time. |
| `POST /api/oltp/orders` | TBD | TBD | TBD | Expected degradation: write path now updates denormalized totals and inserts an audit note. |
| `POST /api/oltp/orders/{id}/status` | TBD | TBD | TBD | Expected degradation: update now touches `last_status_changed_at` and inserts into two history tables. |

## Optimization Plan

| Query / Profile | Problem from EXPLAIN / pg_stat | Proposed solution | Expected effect |
| --- | --- | --- | --- |
| `GET /api/oltp/orders/{id}` / `oltp_read` | Lateral audit lookup is expensive on the large unindexed audit table. | Migration 011: btree index on `customer_order_audit_notes(customer_order_id, created_at DESC)`. | Replace sequential scan with index lookup for one order; lower p95 and shared reads. |
| `GET /api/olap/revenue-by-day` / `olap_revenue` | Large aggregate scans orders, items, products, categories and audit notes. | Migration 013: `mv_revenue_by_day_category`, endpoint reads MV when `API_USE_REVENUE_MV=true`. | Replace runtime multi-table aggregate with small MV range scan. |
| Audit/date range analytics | Append-heavy audit table grows quickly and date filters need cheap pruning. | Migration 012: BRIN index on `customer_order_audit_notes(created_at)`. | Lower maintenance cost than btree and improve broad date range reads. |
| `POST /api/oltp/orders`, `POST /api/oltp/orders/{id}/status` | Extra indexes can slow inserts into `customer_order_audit_notes`. | Run `load/k6_write_script.js` after optimization. | Confirm write p95 remains acceptable and document the index overhead. |

## Write Impact After Optimization

Short write-only run command:

```powershell
docker compose run --rm k6 run --summary-export /profiling/3/k6_write_summary.json /scripts/k6_write_script.js
```

| Write endpoint | p95 point 1 | p95 after optimization | pg_stat / EXPLAIN observation | Result |
| --- | ---: | ---: | --- | --- |
| `POST /api/oltp/orders` | TBD | TBD | TBD | TBD |
| `POST /api/oltp/orders/{id}/status` | TBD | TBD | TBD | TBD |
| `POST /api/log/order-status-events` | TBD | TBD | TBD | TBD |

## Final Summary

| Query / Endpoint | p95 point 1 | p95 point 2 | p95 point 3 | Delta 1->2 | Delta 2->3 | Applied solution |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `GET /api/oltp/orders/{id}` | TBD | TBD | TBD | TBD | TBD | `idx_customer_order_audit_notes_order_created` |
| `POST /api/oltp/orders` | TBD | TBD | TBD | TBD | TBD | Denormalized totals kept; write impact measured after indexes |
| `POST /api/oltp/orders/{id}/status` | TBD | TBD | TBD | TBD | TBD | Audit index plus write impact validation |
| `GET /api/olap/revenue-by-day` | TBD | TBD | TBD | TBD | TBD | `mv_revenue_by_day_category` |
| `GET /api/olap/warehouse-turnover` | TBD | TBD | TBD | TBD | TBD | Existing movement indexes |
| `POST /api/log/order-status-events` | TBD | TBD | TBD | TBD | TBD | Existing time-series table indexes |

## Checklist

- [x] Workload service with 6+ queries across OLTP, OLAP and log/time-series profiles.
- [x] `pg_stat_statements` enabled through migration 007.
- [x] Profiling directories prepared: `profiling/1`, `profiling/2`, `profiling/3`.
- [x] 3 business schema changes implemented in migrations 008-010.
- [ ] Degradation in point 2 measured and explained with real p95, EXPLAIN and pg_stat data.
- [x] Minimum 2 indexes implemented in migrations 011-012.
- [x] Architectural optimization implemented through materialized view in migration 013.
- [ ] INSERT/UPDATE impact measured with the write-only k6 run.
- [x] Grafana dashboard is provisioned from JSON.
- [x] Final summary table is present; fill actual numbers after k6 runs.
