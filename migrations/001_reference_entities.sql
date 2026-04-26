--liquibase formatted sql

--changeset warehouse:001_reference_entities runInTransaction:true
CREATE TABLE IF NOT EXISTS customers (
  customer_id BIGSERIAL PRIMARY KEY,
  full_name TEXT NOT NULL,
  email TEXT NOT NULL UNIQUE,
  phone TEXT,
  created_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS employees (
  employee_id BIGSERIAL PRIMARY KEY,
  full_name TEXT NOT NULL,
  email TEXT NOT NULL UNIQUE,
  position_name TEXT NOT NULL,
  hired_at DATE NOT NULL
);

CREATE TABLE IF NOT EXISTS suppliers (
  supplier_id BIGSERIAL PRIMARY KEY,
  supplier_name TEXT NOT NULL UNIQUE,
  email TEXT,
  phone TEXT
);

CREATE TABLE IF NOT EXISTS warehouses (
  warehouse_id BIGSERIAL PRIMARY KEY,
  warehouse_name TEXT NOT NULL UNIQUE,
  city TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS product_categories (
  category_id BIGSERIAL PRIMARY KEY,
  category_name TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS brands (
  brand_id BIGSERIAL PRIMARY KEY,
  brand_name TEXT NOT NULL UNIQUE
);

--rollback DROP TABLE IF EXISTS brands CASCADE;
--rollback DROP TABLE IF EXISTS product_categories CASCADE;
--rollback DROP TABLE IF EXISTS warehouses CASCADE;
--rollback DROP TABLE IF EXISTS suppliers CASCADE;
--rollback DROP TABLE IF EXISTS employees CASCADE;
--rollback DROP TABLE IF EXISTS customers CASCADE;

--changeset warehouse:001_tag
--tagDatabase v001
--rollback empty
