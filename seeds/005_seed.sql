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
  FROM params, generate_series(1, params.sc * 5) AS gs
)
INSERT INTO shipments (
  shipment_id,
  customer_order_id,
  warehouse_id,
  shipped_by_employee_id,
  shipped_at,
  status
)
SELECT
  500000 + series_data.n,
  400000 + series_data.n,
  warehouse_pool.ids[((series_data.n - 1) % cardinality(warehouse_pool.ids)) + 1],
  employee_pool.ids[((series_data.n - 1) % cardinality(employee_pool.ids)) + 1],
  now() - ((series_data.n % 10) || ' days')::interval,
  CASE (series_data.n % 3)
    WHEN 0 THEN 'created'::shipment_status
    WHEN 1 THEN 'dispatched'::shipment_status
    ELSE 'delivered'::shipment_status
  END
FROM series_data, warehouse_pool, employee_pool
WHERE cardinality(warehouse_pool.ids) > 0
  AND cardinality(employee_pool.ids) > 0
ON CONFLICT (shipment_id) DO UPDATE
SET customer_order_id = EXCLUDED.customer_order_id,
    warehouse_id = EXCLUDED.warehouse_id,
    shipped_by_employee_id = EXCLUDED.shipped_by_employee_id,
    shipped_at = EXCLUDED.shipped_at,
    status = EXCLUDED.status;

WITH params AS (
  SELECT GREATEST(1, :'seed_count'::int) AS sc
),
series_data AS (
  SELECT order_n, line_n
  FROM params,
  generate_series(1, params.sc * 5) AS order_n,
  generate_series(1, 2) AS line_n
)
INSERT INTO shipment_items (
  shipment_item_id,
  shipment_id,
  customer_order_item_id,
  shipped_quantity
)
SELECT
  510000 + ((series_data.order_n - 1) * 2) + series_data.line_n,
  500000 + series_data.order_n,
  410000 + ((series_data.order_n - 1) * 4) + series_data.line_n,
  (series_data.line_n + 1)::numeric(14,3)
FROM series_data
ON CONFLICT (shipment_item_id) DO UPDATE
SET shipment_id = EXCLUDED.shipment_id,
    customer_order_item_id = EXCLUDED.customer_order_item_id,
    shipped_quantity = EXCLUDED.shipped_quantity;

WITH movement_source AS (
  SELECT
    540000 + row_number() OVER (ORDER BY si.shipment_item_id) AS movement_id,
    coi.product_id,
    s.warehouse_id,
    si.shipped_quantity AS quantity,
    s.shipped_at AS moved_at,
    s.shipped_by_employee_id AS employee_id
  FROM shipment_items si
  JOIN shipments s ON s.shipment_id = si.shipment_id
  JOIN customer_order_items coi ON coi.customer_order_item_id = si.customer_order_item_id
)
INSERT INTO inventory_movements (
  inventory_movement_id,
  product_id,
  warehouse_id,
  movement_type,
  quantity,
  moved_at,
  employee_id
)
SELECT
  movement_source.movement_id,
  movement_source.product_id,
  movement_source.warehouse_id,
  'shipment'::inventory_movement_type,
  movement_source.quantity,
  movement_source.moved_at,
  movement_source.employee_id
FROM movement_source
ON CONFLICT (inventory_movement_id) DO UPDATE
SET product_id = EXCLUDED.product_id,
    warehouse_id = EXCLUDED.warehouse_id,
    movement_type = EXCLUDED.movement_type,
    quantity = EXCLUDED.quantity,
    moved_at = EXCLUDED.moved_at,
    employee_id = EXCLUDED.employee_id;

WITH movement_source AS (
  SELECT
    530000 + row_number() OVER (ORDER BY gri.goods_receipt_item_id) AS movement_id,
    soi.product_id,
    gr.warehouse_id,
    gri.received_quantity AS quantity,
    gr.received_at AS moved_at,
    gr.accepted_by_employee_id AS employee_id
  FROM goods_receipt_items gri
  JOIN goods_receipts gr ON gr.goods_receipt_id = gri.goods_receipt_id
  JOIN supplier_order_items soi ON soi.supplier_order_item_id = gri.supplier_order_item_id
)
INSERT INTO inventory_movements (
  inventory_movement_id,
  product_id,
  warehouse_id,
  movement_type,
  quantity,
  moved_at,
  employee_id
)
SELECT
  movement_source.movement_id,
  movement_source.product_id,
  movement_source.warehouse_id,
  'receipt'::inventory_movement_type,
  movement_source.quantity,
  movement_source.moved_at,
  movement_source.employee_id
FROM movement_source
ON CONFLICT (inventory_movement_id) DO UPDATE
SET product_id = EXCLUDED.product_id,
    warehouse_id = EXCLUDED.warehouse_id,
    movement_type = EXCLUDED.movement_type,
    quantity = EXCLUDED.quantity,
    moved_at = EXCLUDED.moved_at,
    employee_id = EXCLUDED.employee_id;

SELECT setval(
  pg_get_serial_sequence('shipments', 'shipment_id'),
  GREATEST((SELECT COALESCE(MAX(shipment_id), 1) FROM shipments), 1),
  true
);
SELECT setval(
  pg_get_serial_sequence('shipment_items', 'shipment_item_id'),
  GREATEST((SELECT COALESCE(MAX(shipment_item_id), 1) FROM shipment_items), 1),
  true
);
SELECT setval(
  pg_get_serial_sequence('inventory_movements', 'inventory_movement_id'),
  GREATEST((SELECT COALESCE(MAX(inventory_movement_id), 1) FROM inventory_movements), 1),
  true
);

