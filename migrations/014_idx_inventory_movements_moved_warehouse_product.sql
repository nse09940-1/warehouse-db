--liquibase formatted sql

--changeset warehouse:014_idx_inventory_movements_moved_warehouse_product runInTransaction:true
CREATE INDEX IF NOT EXISTS idx_inventory_movements_moved_warehouse_product
  ON inventory_movements (moved_at, warehouse_id, product_id, movement_type);

--rollback DROP INDEX IF EXISTS idx_inventory_movements_moved_warehouse_product;

--changeset warehouse:014_tag
--tagDatabase v014
--rollback empty

