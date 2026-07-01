SELECT
  toDate(moved_at) AS movement_day,
  movement_type,
  sum(quantity) AS total_quantity
FROM bi_analytics.inventory_movements_current
WHERE moved_at >= {{date_from}}
  AND moved_at < {{date_to}}
GROUP BY movement_day, movement_type
ORDER BY movement_day, movement_type;
