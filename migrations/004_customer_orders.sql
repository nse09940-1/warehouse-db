--liquibase formatted sql

--changeset warehouse:004_customer_orders runInTransaction:true
DO $$
BEGIN
  CREATE TYPE customer_order_status AS ENUM (
    'new',
    'confirmed',
    'picking',
    'shipped',
    'delivered',
    'cancelled'
  );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
CREATE TABLE IF NOT EXISTS customer_orders (
  customer_order_id BIGSERIAL PRIMARY KEY,
  customer_id BIGINT NOT NULL REFERENCES customers(customer_id),
  delivery_address TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  status customer_order_status NOT NULL
);

CREATE TABLE IF NOT EXISTS customer_order_items (
  customer_order_item_id BIGSERIAL PRIMARY KEY,
  customer_order_id BIGINT NOT NULL REFERENCES customer_orders(customer_order_id),
  product_id BIGINT NOT NULL REFERENCES products(product_id),
  ordered_quantity NUMERIC(14,3) NOT NULL,
  sale_price NUMERIC(14,2) NOT NULL,
  CONSTRAINT uq_customer_order_items UNIQUE (customer_order_id, product_id)
);

--rollback DROP TABLE IF EXISTS customer_order_items CASCADE;
--rollback DROP TABLE IF EXISTS customer_orders CASCADE;
--rollback DROP TYPE IF EXISTS customer_order_status;

--changeset warehouse:004_tag
--tagDatabase v004
--rollback empty
