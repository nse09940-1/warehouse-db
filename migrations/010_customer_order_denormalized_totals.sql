--liquibase formatted sql

--changeset warehouse:010_customer_order_denormalized_totals runInTransaction:true splitStatements:false rollbackSplitStatements:false
ALTER TABLE customer_orders
  ADD COLUMN IF NOT EXISTS total_amount NUMERIC(14,2),
  ADD COLUMN IF NOT EXISTS items_count INTEGER,
  ADD COLUMN IF NOT EXISTS last_status_changed_at TIMESTAMPTZ;

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
    last_status_changed_at = co.created_at
FROM totals
WHERE totals.customer_order_id = co.customer_order_id;

UPDATE customer_orders
SET total_amount = COALESCE(total_amount, 0),
    items_count = COALESCE(items_count, 0),
    last_status_changed_at = COALESCE(last_status_changed_at, created_at);

--rollback ALTER TABLE customer_orders DROP COLUMN IF EXISTS last_status_changed_at;
--rollback ALTER TABLE customer_orders DROP COLUMN IF EXISTS items_count;
--rollback ALTER TABLE customer_orders DROP COLUMN IF EXISTS total_amount;

--changeset warehouse:010_tag
--tagDatabase v010
--rollback empty
