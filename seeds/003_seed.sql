WITH params AS (
  SELECT GREATEST(1, :'seed_count'::int) AS sc
),
supplier_pool AS (
  SELECT array_agg(supplier_id ORDER BY supplier_id) AS ids
  FROM suppliers
),
employee_pool AS (
  SELECT array_agg(employee_id ORDER BY employee_id) AS ids
  FROM employees
),
series_data AS (
  SELECT gs AS n
  FROM params, generate_series(1, params.sc * 2) AS gs
)
INSERT INTO supplier_orders (
  supplier_order_id,
  supplier_id,
  created_by_employee_id,
  order_date,
  status
)
SELECT
  300000 + series_data.n,
  supplier_pool.ids[((series_data.n - 1) % cardinality(supplier_pool.ids)) + 1],
  employee_pool.ids[((series_data.n - 1) % cardinality(employee_pool.ids)) + 1],
  CURRENT_DATE - (series_data.n % 45),
  CASE (series_data.n % 4)
    WHEN 0 THEN 'placed'::supplier_order_status
    WHEN 1 THEN 'partially_received'::supplier_order_status
    WHEN 2 THEN 'received'::supplier_order_status
    ELSE 'draft'::supplier_order_status
  END
FROM series_data, supplier_pool, employee_pool
WHERE cardinality(supplier_pool.ids) > 0
  AND cardinality(employee_pool.ids) > 0
ON CONFLICT (supplier_order_id) DO UPDATE
SET supplier_id = EXCLUDED.supplier_id,
    created_by_employee_id = EXCLUDED.created_by_employee_id,
    order_date = EXCLUDED.order_date,
    status = EXCLUDED.status;

WITH params AS (
  SELECT GREATEST(1, :'seed_count'::int) AS sc
),
product_pool AS (
  SELECT array_agg(product_id ORDER BY product_id) AS ids
  FROM products
),
series_data AS (
  SELECT order_n, line_n
  FROM params,
  generate_series(1, params.sc * 2) AS order_n,
  generate_series(1, 2) AS line_n
)
INSERT INTO supplier_order_items (
  supplier_order_item_id,
  supplier_order_id,
  product_id,
  ordered_quantity,
  unit_price
)
SELECT
  310000 + ((series_data.order_n - 1) * 2) + series_data.line_n,
  300000 + series_data.order_n,
  product_pool.ids[((series_data.order_n + series_data.line_n - 2) % cardinality(product_pool.ids)) + 1],
  (series_data.line_n + (series_data.order_n % 5) + 1)::numeric(14,3),
  (10 + (series_data.order_n % 80))::numeric(14,2)
FROM series_data, product_pool
WHERE cardinality(product_pool.ids) > 0
ON CONFLICT (supplier_order_item_id) DO UPDATE
SET supplier_order_id = EXCLUDED.supplier_order_id,
    product_id = EXCLUDED.product_id,
    ordered_quantity = EXCLUDED.ordered_quantity,
    unit_price = EXCLUDED.unit_price;

WITH params AS (
  SELECT GREATEST(1, :'seed_count'::int) AS sc
),
warehouse_pool AS (
  SELECT array_agg(warehouse_id ORDER BY warehouse_id) AS ids
  FROM warehouses
),
employee_pool AS (
  SELECT array_agg(employee_id ORDER BY employee_id) AS ids
  FROM employees
),
series_data AS (
  SELECT gs AS n
  FROM params, generate_series(1, params.sc * 2) AS gs
)
INSERT INTO goods_receipts (
  goods_receipt_id,
  supplier_order_id,
  warehouse_id,
  accepted_by_employee_id,
  received_at
)
SELECT
  320000 + series_data.n,
  300000 + series_data.n,
  warehouse_pool.ids[((series_data.n - 1) % cardinality(warehouse_pool.ids)) + 1],
  employee_pool.ids[((series_data.n - 1) % cardinality(employee_pool.ids)) + 1],
  now() - ((series_data.n % 20) || ' days')::interval
FROM series_data, warehouse_pool, employee_pool
WHERE cardinality(warehouse_pool.ids) > 0
  AND cardinality(employee_pool.ids) > 0
ON CONFLICT (goods_receipt_id) DO UPDATE
SET supplier_order_id = EXCLUDED.supplier_order_id,
    warehouse_id = EXCLUDED.warehouse_id,
    accepted_by_employee_id = EXCLUDED.accepted_by_employee_id,
    received_at = EXCLUDED.received_at;

WITH params AS (
  SELECT GREATEST(1, :'seed_count'::int) AS sc
),
series_data AS (
  SELECT order_n, line_n
  FROM params,
  generate_series(1, params.sc * 2) AS order_n,
  generate_series(1, 2) AS line_n
)
INSERT INTO goods_receipt_items (
  goods_receipt_item_id,
  goods_receipt_id,
  supplier_order_item_id,
  received_quantity,
  unit_cost,
  expiration_date
)
SELECT
  330000 + ((series_data.order_n - 1) * 2) + series_data.line_n,
  320000 + series_data.order_n,
  310000 + ((series_data.order_n - 1) * 2) + series_data.line_n,
  (series_data.line_n + (series_data.order_n % 5) + 1)::numeric(14,3),
  (12 + (series_data.order_n % 90))::numeric(14,2),
  CURRENT_DATE + (series_data.order_n % 365)
FROM series_data
ON CONFLICT (goods_receipt_item_id) DO UPDATE
SET goods_receipt_id = EXCLUDED.goods_receipt_id,
    supplier_order_item_id = EXCLUDED.supplier_order_item_id,
    received_quantity = EXCLUDED.received_quantity,
    unit_cost = EXCLUDED.unit_cost,
    expiration_date = EXCLUDED.expiration_date;

SELECT setval(
  pg_get_serial_sequence('supplier_orders', 'supplier_order_id'),
  GREATEST((SELECT COALESCE(MAX(supplier_order_id), 1) FROM supplier_orders), 1),
  true
);
SELECT setval(
  pg_get_serial_sequence('supplier_order_items', 'supplier_order_item_id'),
  GREATEST((SELECT COALESCE(MAX(supplier_order_item_id), 1) FROM supplier_order_items), 1),
  true
);
SELECT setval(
  pg_get_serial_sequence('goods_receipts', 'goods_receipt_id'),
  GREATEST((SELECT COALESCE(MAX(goods_receipt_id), 1) FROM goods_receipts), 1),
  true
);
SELECT setval(
  pg_get_serial_sequence('goods_receipt_items', 'goods_receipt_item_id'),
  GREATEST((SELECT COALESCE(MAX(goods_receipt_item_id), 1) FROM goods_receipt_items), 1),
  true
);
