--liquibase formatted sql

--changeset warehouse:008_customer_order_delivery_window runInTransaction:true
ALTER TABLE customer_orders
  ADD COLUMN IF NOT EXISTS delivery_window_start TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS delivery_window_end TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS delivery_priority SMALLINT;

--rollback ALTER TABLE customer_orders DROP COLUMN IF EXISTS delivery_priority;
--rollback ALTER TABLE customer_orders DROP COLUMN IF EXISTS delivery_window_end;
--rollback ALTER TABLE customer_orders DROP COLUMN IF EXISTS delivery_window_start;

--changeset warehouse:008_tag
--tagDatabase v008
--rollback empty
