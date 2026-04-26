WITH params AS (
  SELECT GREATEST(1, :'seed_count'::int) AS sc
),
category_pool AS (
  SELECT array_agg(category_id ORDER BY category_id) AS ids
  FROM product_categories
),
brand_pool AS (
  SELECT array_agg(brand_id ORDER BY brand_id) AS ids
  FROM brands
),
series_data AS (
  SELECT gs AS n
  FROM params, generate_series(1, params.sc * 10) AS gs
)
INSERT INTO products (category_id, brand_id, product_name, unit_of_measure)
SELECT
  category_pool.ids[((series_data.n - 1) % cardinality(category_pool.ids)) + 1],
  brand_pool.ids[((series_data.n - 1) % cardinality(brand_pool.ids)) + 1],
  format('Product %s', series_data.n),
  CASE (series_data.n % 3)
    WHEN 0 THEN 'pcs'
    WHEN 1 THEN 'kg'
    ELSE 'box'
  END
FROM series_data, category_pool, brand_pool
WHERE cardinality(category_pool.ids) > 0
  AND cardinality(brand_pool.ids) > 0
ON CONFLICT (brand_id, product_name) DO UPDATE
SET category_id = EXCLUDED.category_id,
    unit_of_measure = EXCLUDED.unit_of_measure;

