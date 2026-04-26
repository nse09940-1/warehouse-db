WITH params AS (
  SELECT GREATEST(1, :'seed_count'::int) AS sc
)
INSERT INTO product_categories (category_name)
SELECT c.category_name
FROM (VALUES
  ('Electronics'),
  ('Home'),
  ('Books'),
  ('Office'),
  ('Sports'),
  ('Clothing'),
  ('Beauty'),
  ('Food')
) AS c(category_name)
ON CONFLICT (category_name) DO NOTHING;

WITH params AS (
  SELECT GREATEST(1, :'seed_count'::int) AS sc
)
INSERT INTO brands (brand_name)
SELECT format('Brand %s', gs)
FROM params, generate_series(1, GREATEST(10, params.sc * 2)) AS gs
ON CONFLICT (brand_name) DO NOTHING;

WITH params AS (
  SELECT GREATEST(1, :'seed_count'::int) AS sc
)
INSERT INTO warehouses (warehouse_name, city)
SELECT format('Warehouse %s', gs), format('City %s', ((gs - 1) % 5) + 1)
FROM params, generate_series(1, GREATEST(3, params.sc / 2)) AS gs
ON CONFLICT (warehouse_name) DO UPDATE SET city = EXCLUDED.city;

WITH params AS (
  SELECT GREATEST(1, :'seed_count'::int) AS sc
)
INSERT INTO suppliers (supplier_name, email, phone)
SELECT
  format('Supplier %s', gs),
  format('supplier%s@example.com', gs),
  format('+100000%05s', gs)
FROM params, generate_series(1, params.sc * 2) AS gs
ON CONFLICT (supplier_name) DO UPDATE
SET email = EXCLUDED.email,
    phone = EXCLUDED.phone;

WITH params AS (
  SELECT GREATEST(1, :'seed_count'::int) AS sc
)
INSERT INTO employees (full_name, email, position_name, hired_at)
SELECT
  format('Employee %s', gs),
  format('employee%s@example.com', gs),
  CASE (gs % 4)
    WHEN 0 THEN 'manager'
    WHEN 1 THEN 'operator'
    WHEN 2 THEN 'picker'
    ELSE 'accountant'
  END,
  CURRENT_DATE - (gs % 700)
FROM params, generate_series(1, GREATEST(5, params.sc)) AS gs
ON CONFLICT (email) DO UPDATE
SET full_name = EXCLUDED.full_name,
    position_name = EXCLUDED.position_name,
    hired_at = EXCLUDED.hired_at;

WITH params AS (
  SELECT GREATEST(1, :'seed_count'::int) AS sc
)
INSERT INTO customers (full_name, email, phone, created_at)
SELECT
  format('Customer %s', gs),
  format('customer%s@example.com', gs),
  format('+200000%05s', gs),
  now() - ((gs % 365) || ' days')::interval
FROM params, generate_series(1, params.sc * 5) AS gs
ON CONFLICT (email) DO UPDATE
SET full_name = EXCLUDED.full_name,
    phone = EXCLUDED.phone,
    created_at = EXCLUDED.created_at;
