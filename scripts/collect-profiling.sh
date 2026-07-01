#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

require_env POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD

profile_dir="${PROFILE_DIR:-profiling/1}"
output_dir="${WORKSPACE_DIR}/${profile_dir}"
explain_dir="${output_dir}/explain"

mkdir -p "${output_dir}" "${explain_dir}"

sample_order_id="$(
  psql_for_db "${POSTGRES_DB}" -tAc \
    "SELECT customer_order_id FROM customer_orders ORDER BY customer_order_id LIMIT 1;"
)"

if [[ -z "${sample_order_id}" ]]; then
  echo "No orders found in customer_orders; EXPLAIN collection skipped." >&2
  exit 1
fi

from_ts="2020-01-01T00:00:00Z"
to_ts="2100-01-01T00:00:00Z"

pg_stat_csv="${output_dir}/pg_stat_statements.csv"
echo "Exporting pg_stat_statements to ${pg_stat_csv}"
psql_for_db "${POSTGRES_DB}" -v ON_ERROR_STOP=1 -c "\
\\copy (
  SELECT
    query,
    mean_exec_time,
    calls,
    shared_blks_hit,
    shared_blks_read
  FROM pg_stat_statements
  ORDER BY mean_exec_time DESC
  LIMIT 500
) TO '${pg_stat_csv}' WITH (FORMAT csv, HEADER true)"

run_explain() {
  local name="${1}"
  local sql="${2}"
  local file_path="${explain_dir}/${name}.txt"
  echo "Collecting EXPLAIN for ${name}"
  psql_for_db "${POSTGRES_DB}" -v ON_ERROR_STOP=1 -X -qAt \
    -c "EXPLAIN (ANALYZE, BUFFERS, VERBOSE) ${sql}" > "${file_path}"
}

run_explain "oltp_read_order" "
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
WHERE co.customer_order_id = ${sample_order_id}
ORDER BY coi.customer_order_item_id"

run_explain "oltp_insert_order" "
WITH selected_customer AS (
  SELECT customer_id
  FROM customers
  ORDER BY random()
  LIMIT 1
),
selected_products AS (
  SELECT
    product_id,
    (row_number() OVER () + 1)::numeric(14,3) AS ordered_quantity,
    (20 + floor(random() * 150))::numeric(14,2) AS sale_price
  FROM products
  ORDER BY random()
  LIMIT 3
),
item_totals AS (
  SELECT
    sum(ordered_quantity * sale_price)::numeric(14,2) AS total_amount,
    count(*)::integer AS items_count
  FROM selected_products
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
  SELECT
    customer_id,
    format('Profile street %s', floor(random() * 1000)::int),
    now(),
    'new'::customer_order_status,
    now() + interval '1 day',
    now() + interval '1 day 4 hours',
    1,
    item_totals.total_amount,
    item_totals.items_count,
    now()
  FROM selected_customer
  CROSS JOIN item_totals
  RETURNING customer_order_id
),
inserted_items AS (
  INSERT INTO customer_order_items (customer_order_id, product_id, ordered_quantity, sale_price)
  SELECT new_order.customer_order_id, selected_products.product_id, selected_products.ordered_quantity, selected_products.sale_price
  FROM new_order
  JOIN selected_products ON true
  RETURNING customer_order_id
),
inserted_audit_note AS (
  INSERT INTO customer_order_audit_notes (customer_order_id, note_type, note_text, created_at)
  SELECT customer_order_id, 'operator', 'Order created by collect-profiling script', now()
  FROM new_order
)
SELECT count(*) FROM inserted_items"

run_explain "oltp_update_status" "
WITH target_order AS (
  SELECT customer_order_id, status AS old_status
  FROM customer_orders
  WHERE customer_order_id = ${sample_order_id}
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
  SELECT target_order.customer_order_id, target_order.old_status, updated_order.new_status, 'collect-profiling', now()
  FROM target_order
  JOIN updated_order ON updated_order.customer_order_id = target_order.customer_order_id
  RETURNING order_status_event_id
),
inserted_audit_note AS (
  INSERT INTO customer_order_audit_notes (customer_order_id, note_type, note_text, created_at)
  SELECT target_order.customer_order_id, 'status', 'Status updated by collect-profiling script', now()
  FROM target_order
  JOIN updated_order ON updated_order.customer_order_id = target_order.customer_order_id
  RETURNING audit_note_id
)
SELECT count(*) FROM inserted_event"

run_explain "olap_revenue_by_day" "
WITH audit_counts AS (
  SELECT customer_order_id, count(*) AS audit_note_count
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
  WHERE co.created_at >= '${from_ts}'::timestamptz
    AND co.created_at < '${to_ts}'::timestamptz
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
LIMIT 100"

if psql_for_db "${POSTGRES_DB}" -tAc \
  "SELECT 1 FROM pg_matviews WHERE matviewname = 'mv_revenue_by_day_category' LIMIT 1;" \
  | grep -q "1"; then
  run_explain "olap_revenue_by_day_mv" "
SELECT
  sales_day,
  category_name,
  order_count,
  revenue,
  audit_note_count
FROM mv_revenue_by_day_category
WHERE sales_day >= ('${from_ts}'::timestamptz)::date
  AND sales_day < ('${to_ts}'::timestamptz)::date
ORDER BY sales_day DESC, revenue DESC
LIMIT 100"
fi

run_explain "olap_warehouse_turnover" "
WITH top_warehouses AS (
  SELECT
    im.warehouse_id,
    sum(im.quantity) AS warehouse_total_quantity
  FROM inventory_movements im
  WHERE im.moved_at >= '${from_ts}'::timestamptz
    AND im.moved_at < '${to_ts}'::timestamptz
  GROUP BY im.warehouse_id
  ORDER BY warehouse_total_quantity DESC
  LIMIT 100
),
movement_totals AS (
  SELECT
    w.warehouse_id,
    w.warehouse_name,
    p.product_id,
    p.product_name,
    sum(CASE WHEN im.movement_type = 'receipt' THEN im.quantity ELSE 0 END) AS received_quantity,
    sum(CASE WHEN im.movement_type = 'shipment' THEN im.quantity ELSE 0 END) AS shipped_quantity,
    sum(CASE WHEN im.movement_type IN ('write_off', 'adjustment') THEN im.quantity ELSE 0 END) AS adjusted_quantity
  FROM inventory_movements im
  JOIN top_warehouses tw ON tw.warehouse_id = im.warehouse_id
  JOIN warehouses w ON w.warehouse_id = im.warehouse_id
  JOIN products p ON p.product_id = im.product_id
  WHERE im.moved_at >= '${from_ts}'::timestamptz
    AND im.moved_at < '${to_ts}'::timestamptz
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
SELECT
  warehouse_id,
  warehouse_name,
  product_id,
  product_name,
  received_quantity,
  shipped_quantity,
  adjusted_quantity,
  total_quantity,
  product_rank
FROM ranked
WHERE product_rank <= 10
ORDER BY warehouse_name, product_rank, product_name"

run_explain "log_insert_event" "
WITH selected_order AS (
  SELECT customer_order_id, status AS old_status
  FROM customer_orders
  ORDER BY random()
  LIMIT 1
),
inserted_event AS (
  INSERT INTO order_status_events (
    customer_order_id,
    old_status,
    new_status,
    event_source,
    created_at
  )
  SELECT
    selected_order.customer_order_id,
    selected_order.old_status,
    'shipped'::customer_order_status,
    'collect-profiling',
    now()
  FROM selected_order
  RETURNING order_status_event_id
)
SELECT count(*) FROM inserted_event"

echo "Profiling artifacts are collected in ${profile_dir}"
