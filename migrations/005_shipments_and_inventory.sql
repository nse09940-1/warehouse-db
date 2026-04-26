--liquibase formatted sql

--changeset warehouse:005_shipments_and_inventory runInTransaction:true
DO $$
BEGIN
  CREATE TYPE shipment_status AS ENUM (
    'created',
    'dispatched',
    'delivered',
    'cancelled'
  );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
DO $$
BEGIN
  CREATE TYPE inventory_movement_type AS ENUM (
    'receipt',
    'shipment',
    'write_off',
    'adjustment'
  );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
CREATE TABLE IF NOT EXISTS shipments (
  shipment_id BIGSERIAL PRIMARY KEY,
  customer_order_id BIGINT NOT NULL REFERENCES customer_orders(customer_order_id),
  warehouse_id BIGINT NOT NULL REFERENCES warehouses(warehouse_id),
  shipped_by_employee_id BIGINT NOT NULL REFERENCES employees(employee_id),
  shipped_at TIMESTAMPTZ NOT NULL,
  status shipment_status NOT NULL
);

CREATE TABLE IF NOT EXISTS shipment_items (
  shipment_item_id BIGSERIAL PRIMARY KEY,
  shipment_id BIGINT NOT NULL REFERENCES shipments(shipment_id),
  customer_order_item_id BIGINT NOT NULL REFERENCES customer_order_items(customer_order_item_id),
  shipped_quantity NUMERIC(14,3) NOT NULL,
  CONSTRAINT uq_shipment_items UNIQUE (shipment_id, customer_order_item_id)
);

CREATE TABLE IF NOT EXISTS inventory_movements (
  inventory_movement_id BIGSERIAL PRIMARY KEY,
  product_id BIGINT NOT NULL REFERENCES products(product_id),
  warehouse_id BIGINT NOT NULL REFERENCES warehouses(warehouse_id),
  movement_type inventory_movement_type NOT NULL,
  quantity NUMERIC(14,3) NOT NULL,
  moved_at TIMESTAMPTZ NOT NULL,
  employee_id BIGINT NOT NULL REFERENCES employees(employee_id)
);

--rollback DROP TABLE IF EXISTS inventory_movements CASCADE;
--rollback DROP TABLE IF EXISTS shipment_items CASCADE;
--rollback DROP TABLE IF EXISTS shipments CASCADE;
--rollback DROP TYPE IF EXISTS inventory_movement_type;
--rollback DROP TYPE IF EXISTS shipment_status;

--changeset warehouse:005_tag
--tagDatabase v005
--rollback empty
