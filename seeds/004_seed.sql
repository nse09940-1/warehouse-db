WITH params AS (
  SELECT GREATEST(1, :'seed_count'::int) AS sc
),
customer_bounds AS (
  SELECT
    MIN(customer_id) AS min_id,
    COUNT(*)::bigint AS total_count
  FROM customers
),
series_data AS (
  SELECT gs AS n
  FROM params, generate_series(1, params.sc * 5) AS gs
)
INSERT INTO customer_orders (
  customer_order_id,
  customer_id,
  delivery_address,
  created_at,
  status
)
SELECT
  400000 + series_data.n,
  customer_bounds.min_id + ((series_data.n - 1) % customer_bounds.total_count),
  format('Street %s, Building %s', ((series_data.n - 1) % 70) + 1, ((series_data.n - 1) % 30) + 1),
  now() - ((series_data.n % 25) || ' days')::interval,
  CASE (series_data.n % 5)
    WHEN 0 THEN 'new'::customer_order_status
    WHEN 1 THEN 'confirmed'::customer_order_status
    WHEN 2 THEN 'picking'::customer_order_status
    WHEN 3 THEN 'shipped'::customer_order_status
    ELSE 'delivered'::customer_order_status
  END
FROM series_data, customer_bounds
WHERE customer_bounds.total_count > 0
ON CONFLICT (customer_order_id) DO UPDATE
SET customer_id = EXCLUDED.customer_id,
    delivery_address = EXCLUDED.delivery_address,
    created_at = EXCLUDED.created_at,
    status = EXCLUDED.status;

WITH params AS (
  SELECT GREATEST(1, :'seed_count'::int) AS sc
),
product_bounds AS (
  SELECT
    MIN(product_id) AS min_id,
    COUNT(*)::bigint AS total_count
  FROM products
),
series_data AS (
  SELECT order_n, line_n
  FROM params,
  generate_series(1, params.sc * 5) AS order_n,
  generate_series(1, 4) AS line_n
)
INSERT INTO customer_order_items (
  customer_order_item_id,
  customer_order_id,
  product_id,
  ordered_quantity,
  sale_price
)
SELECT
  410000 + ((series_data.order_n - 1) * 4) + series_data.line_n,
  400000 + series_data.order_n,
  product_bounds.min_id + ((series_data.order_n + series_data.line_n - 2) % product_bounds.total_count),
  (series_data.line_n + 1)::numeric(14,3),
  (20 + ((series_data.order_n + series_data.line_n) % 120))::numeric(14,2)
FROM series_data, product_bounds
WHERE product_bounds.total_count > 0
ON CONFLICT (customer_order_item_id) DO UPDATE
SET customer_order_id = EXCLUDED.customer_order_id,
    product_id = EXCLUDED.product_id,
    ordered_quantity = EXCLUDED.ordered_quantity,
    sale_price = EXCLUDED.sale_price;

SELECT setval(
  pg_get_serial_sequence('customer_orders', 'customer_order_id'),
  GREATEST((SELECT COALESCE(MAX(customer_order_id), 1) FROM customer_orders), 1),
  true
);
SELECT setval(
  pg_get_serial_sequence('customer_order_items', 'customer_order_item_id'),
  GREATEST((SELECT COALESCE(MAX(customer_order_item_id), 1) FROM customer_order_items), 1),
  true
);
