--liquibase formatted sql

--changeset warehouse:003_procurement runInTransaction:true
DO $$
BEGIN
  CREATE TYPE supplier_order_status AS ENUM (
    'draft',
    'placed',
    'partially_received',
    'received',
    'cancelled'
  );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
CREATE TABLE IF NOT EXISTS supplier_orders (
  supplier_order_id BIGSERIAL PRIMARY KEY,
  supplier_id BIGINT NOT NULL REFERENCES suppliers(supplier_id),
  created_by_employee_id BIGINT NOT NULL REFERENCES employees(employee_id),
  order_date DATE NOT NULL,
  status supplier_order_status NOT NULL
);

CREATE TABLE IF NOT EXISTS supplier_order_items (
  supplier_order_item_id BIGSERIAL PRIMARY KEY,
  supplier_order_id BIGINT NOT NULL REFERENCES supplier_orders(supplier_order_id),
  product_id BIGINT NOT NULL REFERENCES products(product_id),
  ordered_quantity NUMERIC(14,3) NOT NULL,
  unit_price NUMERIC(14,2) NOT NULL,
  CONSTRAINT uq_supplier_order_items UNIQUE (supplier_order_id, product_id)
);

CREATE TABLE IF NOT EXISTS goods_receipts (
  goods_receipt_id BIGSERIAL PRIMARY KEY,
  supplier_order_id BIGINT NOT NULL REFERENCES supplier_orders(supplier_order_id),
  warehouse_id BIGINT NOT NULL REFERENCES warehouses(warehouse_id),
  accepted_by_employee_id BIGINT NOT NULL REFERENCES employees(employee_id),
  received_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS goods_receipt_items (
  goods_receipt_item_id BIGSERIAL PRIMARY KEY,
  goods_receipt_id BIGINT NOT NULL REFERENCES goods_receipts(goods_receipt_id),
  supplier_order_item_id BIGINT NOT NULL REFERENCES supplier_order_items(supplier_order_item_id),
  received_quantity NUMERIC(14,3) NOT NULL,
  unit_cost NUMERIC(14,2) NOT NULL,
  expiration_date DATE,
  CONSTRAINT uq_goods_receipt_items UNIQUE (goods_receipt_id, supplier_order_item_id)
);

--rollback DROP TABLE IF EXISTS goods_receipt_items CASCADE;
--rollback DROP TABLE IF EXISTS goods_receipts CASCADE;
--rollback DROP TABLE IF EXISTS supplier_order_items CASCADE;
--rollback DROP TABLE IF EXISTS supplier_orders CASCADE;
--rollback DROP TYPE IF EXISTS supplier_order_status;

--changeset warehouse:003_tag
--tagDatabase v003
--rollback empty
