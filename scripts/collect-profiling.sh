#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

require_env POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD

PROFILE_DIR="${PROFILE_DIR:-profiling/1}"
OUT_DIR="${WORKSPACE_DIR}/${PROFILE_DIR}"
EXPLAIN_DIR="${OUT_DIR}/explain"
mkdir -p "${EXPLAIN_DIR}"

psql_for_db "${POSTGRES_DB}" -v ON_ERROR_STOP=1 <<SQL
\copy (
  SELECT
    query,
    mean_exec_time,
    calls,
    shared_blks_hit,
    shared_blks_read
  FROM pg_stat_statements
  WHERE dbid = (
    SELECT oid
    FROM pg_database
    WHERE datname = current_database()
  )
  ORDER BY mean_exec_time DESC
) TO '${OUT_DIR}/pg_stat_statements.csv' WITH CSV HEADER
SQL

psql_for_db "${POSTGRES_DB}" -v ON_ERROR_STOP=1 -o "${EXPLAIN_DIR}/oltp_order_read.txt" <<'SQL'
EXPLAIN (ANALYZE, BUFFERS)
SELECT
  co.customer_order_id,
  co.customer_id,
  c.full_name,
  co.delivery_address,
  co.created_at,
  co.status::text AS status,
  co.delivery_priority,
  co.total_amount,
  co.items_count,
  audit_notes.audit_note_count,
  audit_notes.last_audit_note,
  coi.customer_order_item_id,
  coi.ordered_quantity,
  coi.sale_price,
  p.product_id,
  p.product_name,
  b.brand_name,
  pc.category_name
FROM customer_orders co
JOIN customers c ON c.customer_id = co.customer_id
JOIN customer_order_items coi ON coi.customer_order_id = co.customer_order_id
JOIN products p ON p.product_id = coi.product_id
JOIN brands b ON b.brand_id = p.brand_id
JOIN product_categories pc ON pc.category_id = p.category_id
LEFT JOIN LATERAL (
  SELECT
    count(*) AS audit_note_count,
    (array_agg(aon.note_text ORDER BY aon.created_at DESC))[1] AS last_audit_note
  FROM customer_order_audit_notes aon
  WHERE aon.customer_order_id = co.customer_order_id
) audit_notes ON true
WHERE co.customer_order_id = 400001
ORDER BY coi.customer_order_item_id;
SQL

psql_for_db "${POSTGRES_DB}" -v ON_ERROR_STOP=1 -o "${EXPLAIN_DIR}/oltp_order_insert.txt" <<'SQL'
EXPLAIN (ANALYZE, BUFFERS)
WITH selected_customer AS (
  SELECT customer_id
  FROM customers
  ORDER BY random()
  LIMIT 1
),
new_order AS (
  INSERT INTO customer_orders (
    customer_id,
    delivery_address,
    created_at,
    status,
    delivery_window_start,
    delivery_window_end,
    delivery_priority,
    total_amount,
    items_count,
    last_status_changed_at
  )
  SELECT customer_id, 'Explain street', now(), 'new'::customer_order_status,
         now() + interval '1 day', now() + interval '1 day 4 hours',
         1, 0::numeric(14,2), 0, now()
  FROM selected_customer
  RETURNING customer_order_id, customer_id, delivery_address, created_at, status
),
selected_products AS (
  SELECT product_id, row_number() OVER () AS rn
  FROM products
  ORDER BY random()
  LIMIT 3
),
inserted_items AS (
  INSERT INTO customer_order_items (customer_order_id, product_id, ordered_quantity, sale_price)
  SELECT new_order.customer_order_id, selected_products.product_id,
         (selected_products.rn + 1)::numeric(14,3), 20::numeric(14,2)
  FROM new_order
  JOIN selected_products ON true
  RETURNING customer_order_id
),
item_totals AS (
  SELECT customer_order_id,
         sum(ordered_quantity * sale_price)::numeric(14,2) AS total_amount,
         count(*)::integer AS items_count
  FROM customer_order_items
  WHERE customer_order_id = (SELECT customer_order_id FROM new_order)
  GROUP BY customer_order_id
),
updated_order AS (
  UPDATE customer_orders co
  SET total_amount = item_totals.total_amount,
      items_count = item_totals.items_count
  FROM item_totals
  WHERE co.customer_order_id = item_totals.customer_order_id
  RETURNING co.customer_order_id, co.total_amount, co.items_count
),
inserted_audit_note AS (
  INSERT INTO customer_order_audit_notes (customer_order_id, note_type, note_text, created_at)
  SELECT new_order.customer_order_id, 'operator', 'Order created by EXPLAIN workload', now()
  FROM new_order
  RETURNING customer_order_id
)
SELECT new_order.customer_order_id, updated_order.total_amount, updated_order.items_count
FROM new_order
JOIN updated_order ON updated_order.customer_order_id = new_order.customer_order_id
LEFT JOIN inserted_audit_note ON inserted_audit_note.customer_order_id = new_order.customer_order_id;
SQL

psql_for_db "${POSTGRES_DB}" -v ON_ERROR_STOP=1 -o "${EXPLAIN_DIR}/oltp_status_update.txt" <<'SQL'
EXPLAIN (ANALYZE, BUFFERS)
WITH target_order AS (
  SELECT customer_order_id, status AS old_status
  FROM customer_orders
  WHERE customer_order_id = 400002
  FOR UPDATE
),
updated_order AS (
  UPDATE customer_orders co
  SET status = 'confirmed'::customer_order_status,
      last_status_changed_at = now()
  FROM target_order
  WHERE co.customer_order_id = target_order.customer_order_id
  RETURNING co.customer_order_id, co.status AS new_status
),
inserted_event AS (
  INSERT INTO order_status_events (customer_order_id, old_status, new_status, event_source, created_at)
  SELECT target_order.customer_order_id, target_order.old_status, updated_order.new_status, 'explain', now()
  FROM target_order
  JOIN updated_order ON updated_order.customer_order_id = target_order.customer_order_id
  RETURNING order_status_event_id
),
inserted_audit_note AS (
  INSERT INTO customer_order_audit_notes (customer_order_id, note_type, note_text, created_at)
  SELECT target_order.customer_order_id, 'status',
         format('Status changed from %s to %s by EXPLAIN workload', target_order.old_status, updated_order.new_status),
         now()
  FROM target_order
  JOIN updated_order ON updated_order.customer_order_id = target_order.customer_order_id
  RETURNING audit_note_id
)
SELECT target_order.customer_order_id,
       target_order.old_status,
       updated_order.new_status,
       inserted_event.order_status_event_id,
       inserted_audit_note.audit_note_id
FROM target_order
JOIN updated_order ON updated_order.customer_order_id = target_order.customer_order_id
JOIN inserted_event ON true
JOIN inserted_audit_note ON true;
SQL

psql_for_db "${POSTGRES_DB}" -v ON_ERROR_STOP=1 -o "${EXPLAIN_DIR}/olap_revenue_by_day_degraded.txt" <<'SQL'
EXPLAIN (ANALYZE, BUFFERS)
WITH audit_counts AS (
  SELECT
    customer_order_id,
    count(*) AS audit_note_count
  FROM customer_order_audit_notes
  GROUP BY customer_order_id
),
order_category_revenue AS (
  SELECT
    co.customer_order_id,
    date_trunc('day', co.created_at)::date AS sales_day,
    pc.category_name,
    sum(coi.ordered_quantity * coi.sale_price) AS revenue
  FROM customer_orders co
  JOIN customer_order_items coi ON coi.customer_order_id = co.customer_order_id
  JOIN products p ON p.product_id = coi.product_id
  JOIN product_categories pc ON pc.category_id = p.category_id
  WHERE co.created_at >= '2020-01-01T00:00:00Z'::timestamptz
    AND co.created_at < '2100-01-01T00:00:00Z'::timestamptz
  GROUP BY co.customer_order_id, sales_day, pc.category_name
)
SELECT
  ocr.sales_day,
  ocr.category_name,
  count(DISTINCT ocr.customer_order_id) AS order_count,
  sum(ocr.revenue) AS revenue,
  sum(COALESCE(audit_counts.audit_note_count, 0)) AS audit_note_count
FROM order_category_revenue ocr
LEFT JOIN audit_counts ON audit_counts.customer_order_id = ocr.customer_order_id
GROUP BY ocr.sales_day, ocr.category_name
ORDER BY sales_day DESC, revenue DESC
LIMIT 100;
SQL

if [[ "$(psql_for_db "${POSTGRES_DB}" -tAc "SELECT to_regclass('public.mv_revenue_by_day_category') IS NOT NULL;")" == "t" ]]; then
  psql_for_db "${POSTGRES_DB}" -v ON_ERROR_STOP=1 -o "${EXPLAIN_DIR}/olap_revenue_by_day_mv.txt" <<'SQL'
EXPLAIN (ANALYZE, BUFFERS)
SELECT
  sales_day,
  category_name,
  order_count,
  revenue,
  audit_note_count
FROM mv_revenue_by_day_category
WHERE sales_day >= ('2020-01-01T00:00:00Z'::timestamptz)::date
  AND sales_day < ('2100-01-01T00:00:00Z'::timestamptz)::date
ORDER BY sales_day DESC, revenue DESC
LIMIT 100;
SQL
fi

psql_for_db "${POSTGRES_DB}" -v ON_ERROR_STOP=1 -o "${EXPLAIN_DIR}/olap_warehouse_turnover.txt" <<'SQL'
EXPLAIN (ANALYZE, BUFFERS)
WITH movement_totals AS (
  SELECT
    w.warehouse_id,
    w.warehouse_name,
    p.product_id,
    p.product_name,
    sum(CASE WHEN im.movement_type = 'receipt' THEN im.quantity ELSE 0 END) AS received_quantity,
    sum(CASE WHEN im.movement_type = 'shipment' THEN im.quantity ELSE 0 END) AS shipped_quantity,
    sum(CASE WHEN im.movement_type IN ('write_off', 'adjustment') THEN im.quantity ELSE 0 END) AS adjusted_quantity
  FROM inventory_movements im
  JOIN warehouses w ON w.warehouse_id = im.warehouse_id
  JOIN products p ON p.product_id = im.product_id
  WHERE im.moved_at >= '2020-01-01T00:00:00Z'::timestamptz
    AND im.moved_at < '2100-01-01T00:00:00Z'::timestamptz
  GROUP BY w.warehouse_id, w.warehouse_name, p.product_id, p.product_name
),
ranked AS (
  SELECT
    *,
    (received_quantity + shipped_quantity + adjusted_quantity) AS total_quantity,
    dense_rank() OVER (
      PARTITION BY warehouse_id
      ORDER BY (received_quantity + shipped_quantity + adjusted_quantity) DESC
    ) AS product_rank
  FROM movement_totals
  WHERE (received_quantity + shipped_quantity + adjusted_quantity) >= 1::numeric
)
SELECT *
FROM ranked
WHERE product_rank <= 10
ORDER BY warehouse_name, product_rank, product_name;
SQL

psql_for_db "${POSTGRES_DB}" -v ON_ERROR_STOP=1 -o "${EXPLAIN_DIR}/log_status_event_insert.txt" <<'SQL'
EXPLAIN (ANALYZE, BUFFERS)
WITH selected_order AS (
  SELECT customer_order_id, status AS old_status
  FROM customer_orders
  ORDER BY random()
  LIMIT 1
),
inserted_event AS (
  INSERT INTO order_status_events (customer_order_id, old_status, new_status, event_source, created_at)
  SELECT selected_order.customer_order_id, selected_order.old_status, 'confirmed'::customer_order_status, 'explain', now()
  FROM selected_order
  RETURNING order_status_event_id, customer_order_id, created_at
)
SELECT order_status_event_id, customer_order_id, created_at
FROM inserted_event;
SQL

echo "Profiling artifacts exported to ${OUT_DIR}"
