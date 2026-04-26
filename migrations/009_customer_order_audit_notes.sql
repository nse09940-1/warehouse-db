--liquibase formatted sql

--changeset warehouse:009_customer_order_audit_notes runInTransaction:true
CREATE TABLE IF NOT EXISTS customer_order_audit_notes (
  audit_note_id BIGSERIAL PRIMARY KEY,
  customer_order_id BIGINT NOT NULL REFERENCES customer_orders(customer_order_id),
  note_type TEXT NOT NULL,
  note_text TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

--rollback DROP TABLE IF EXISTS customer_order_audit_notes CASCADE;

--changeset warehouse:009_tag
--tagDatabase v009
--rollback empty
