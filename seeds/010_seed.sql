WITH totals AS (
  SELECT
    customer_order_id,
    sum(ordered_quantity * sale_price)::numeric(14,2) AS total_amount,
    count(*)::integer AS items_count
  FROM customer_order_items
  GROUP BY customer_order_id
)
UPDATE customer_orders co
SET total_amount = COALESCE(totals.total_amount, 0),
    items_count = COALESCE(totals.items_count, 0),
    last_status_changed_at = COALESCE(co.last_status_changed_at, co.created_at)
FROM totals
WHERE totals.customer_order_id = co.customer_order_id;

UPDATE customer_orders
SET total_amount = COALESCE(total_amount, 0),
    items_count = COALESCE(items_count, 0),
    last_status_changed_at = COALESCE(last_status_changed_at, created_at)
WHERE total_amount IS NULL
   OR items_count IS NULL
   OR last_status_changed_at IS NULL;
