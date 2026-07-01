SELECT
  sum(quantity) AS total_moved_quantity
FROM bi_analytics.inventory_movements_current
WHERE moved_at >= {{date_from}}
  AND moved_at < {{date_to}};
