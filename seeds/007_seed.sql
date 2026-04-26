WITH params AS (
  SELECT GREATEST(1, :'seed_count'::int) AS sc
),
order_pool AS (
  SELECT
    customer_order_id,
    status,
    row_number() OVER (ORDER BY customer_order_id) AS rn
  FROM customer_orders
),
series_data AS (
  SELECT gs AS n
  FROM params, generate_series(1, params.sc * 10) AS gs
),
order_count AS (
  SELECT count(*) AS cnt
  FROM order_pool
)
INSERT INTO order_status_events (
  order_status_event_id,
  customer_order_id,
  old_status,
  new_status,
  event_source,
  created_at
)
SELECT
  700000 + series_data.n,
  order_pool.customer_order_id,
  CASE (series_data.n % 5)
    WHEN 0 THEN 'new'::customer_order_status
    WHEN 1 THEN 'confirmed'::customer_order_status
    WHEN 2 THEN 'picking'::customer_order_status
    WHEN 3 THEN 'shipped'::customer_order_status
    ELSE NULL
  END,
  order_pool.status,
  CASE (series_data.n % 3)
    WHEN 0 THEN 'seed-api'
    WHEN 1 THEN 'seed-worker'
    ELSE 'seed-import'
  END,
  now() - ((series_data.n % 60) || ' days')::interval
FROM series_data
JOIN order_count ON order_count.cnt > 0
JOIN order_pool ON order_pool.rn = ((series_data.n - 1) % order_count.cnt) + 1
ON CONFLICT (order_status_event_id) DO UPDATE
SET customer_order_id = EXCLUDED.customer_order_id,
    old_status = EXCLUDED.old_status,
    new_status = EXCLUDED.new_status,
    event_source = EXCLUDED.event_source,
    created_at = EXCLUDED.created_at;

SELECT setval(
  pg_get_serial_sequence('order_status_events', 'order_status_event_id'),
  GREATEST((SELECT COALESCE(MAX(order_status_event_id), 1) FROM order_status_events), 1),
  true
);
