WITH params AS (
  SELECT GREATEST(1, :'seed_count'::int) AS sc
),
order_pool AS (
  SELECT
    customer_order_id,
    row_number() OVER (ORDER BY customer_order_id) AS rn
  FROM customer_orders
),
order_count AS (
  SELECT count(*) AS cnt
  FROM order_pool
),
series_data AS (
  SELECT gs AS n
  FROM params, generate_series(1, params.sc * 25) AS gs
)
INSERT INTO customer_order_audit_notes (
  audit_note_id,
  customer_order_id,
  note_type,
  note_text,
  created_at
)
SELECT
  900000 + series_data.n,
  order_pool.customer_order_id,
  CASE (series_data.n % 4)
    WHEN 0 THEN 'delivery'
    WHEN 1 THEN 'payment'
    WHEN 2 THEN 'operator'
    ELSE 'status'
  END,
  format('Seed audit note %s for order %s', series_data.n, order_pool.customer_order_id),
  now() - ((series_data.n % 90) || ' days')::interval
FROM series_data
JOIN order_count ON order_count.cnt > 0
JOIN order_pool ON order_pool.rn = ((series_data.n - 1) % order_count.cnt) + 1
ON CONFLICT (audit_note_id) DO UPDATE
SET customer_order_id = EXCLUDED.customer_order_id,
    note_type = EXCLUDED.note_type,
    note_text = EXCLUDED.note_text,
    created_at = EXCLUDED.created_at;

SELECT setval(
  pg_get_serial_sequence('customer_order_audit_notes', 'audit_note_id'),
  GREATEST((SELECT COALESCE(MAX(audit_note_id), 1) FROM customer_order_audit_notes), 1),
  true
);
