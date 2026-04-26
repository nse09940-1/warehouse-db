--liquibase formatted sql

--changeset warehouse:002_products runInTransaction:true
CREATE TABLE IF NOT EXISTS products (
  product_id BIGSERIAL PRIMARY KEY,
  category_id BIGINT NOT NULL REFERENCES product_categories(category_id),
  brand_id BIGINT NOT NULL REFERENCES brands(brand_id),
  product_name TEXT NOT NULL,
  unit_of_measure TEXT NOT NULL,
  CONSTRAINT uq_products_brand_name UNIQUE (brand_id, product_name)
);

--rollback DROP TABLE IF EXISTS products CASCADE;

--changeset warehouse:002_tag
--tagDatabase v002
--rollback empty
