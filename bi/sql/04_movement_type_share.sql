SELECT
  movement_type,
  toFloat64(sum(quantity)) AS total_quantity
FROM bi_analytics.inventory_movements_current
GROUP BY movement_type
ORDER BY total_quantity DESC;
