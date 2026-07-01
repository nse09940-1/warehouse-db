SELECT
  concat('Warehouse ', toString(warehouse_id)) AS warehouse_name,
  sum(quantity) AS total_quantity
FROM bi_analytics.inventory_movements_current
WHERE moved_at >= {{date_from}}
  AND moved_at < {{date_to}}
GROUP BY warehouse_name
ORDER BY total_quantity DESC
LIMIT 10;
