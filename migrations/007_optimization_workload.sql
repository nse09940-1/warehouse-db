--liquibase formatted sql

--changeset warehouse:007_optimization_workload runInTransaction:true splitStatements:false rollbackSplitStatements:false
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

CREATE TABLE IF NOT EXISTS order_status_events (
  order_status_event_id BIGSERIAL PRIMARY KEY,
  customer_order_id BIGINT NOT NULL REFERENCES customer_orders(customer_order_id),
  old_status customer_order_status,
  new_status customer_order_status NOT NULL,
  event_source TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_customer_orders_created_at
  ON customer_orders (created_at);

CREATE INDEX IF NOT EXISTS idx_customer_orders_status_created_at
  ON customer_orders (status, created_at);

CREATE INDEX IF NOT EXISTS idx_customer_order_items_order_id
  ON customer_order_items (customer_order_id);

CREATE INDEX IF NOT EXISTS idx_customer_order_items_product_id
  ON customer_order_items (product_id);

CREATE INDEX IF NOT EXISTS idx_inventory_movements_moved_at
  ON inventory_movements (moved_at);

CREATE INDEX IF NOT EXISTS idx_inventory_movements_warehouse_moved_at
  ON inventory_movements (warehouse_id, moved_at);

CREATE INDEX IF NOT EXISTS idx_order_status_events_created_at
  ON order_status_events (created_at);

CREATE INDEX IF NOT EXISTS idx_order_status_events_order_created_at
  ON order_status_events (customer_order_id, created_at DESC);

--rollback DROP INDEX IF EXISTS idx_order_status_events_order_created_at;
--rollback DROP INDEX IF EXISTS idx_order_status_events_created_at;
--rollback DROP INDEX IF EXISTS idx_inventory_movements_warehouse_moved_at;
--rollback DROP INDEX IF EXISTS idx_inventory_movements_moved_at;
--rollback DROP INDEX IF EXISTS idx_customer_order_items_product_id;
--rollback DROP INDEX IF EXISTS idx_customer_order_items_order_id;
--rollback DROP INDEX IF EXISTS idx_customer_orders_status_created_at;
--rollback DROP INDEX IF EXISTS idx_customer_orders_created_at;
--rollback DROP TABLE IF EXISTS order_status_events CASCADE;
--rollback DROP EXTENSION IF EXISTS pg_stat_statements;

--changeset warehouse:007_tag
--tagDatabase v007
--rollback empty
