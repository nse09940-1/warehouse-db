--liquibase formatted sql

--changeset warehouse:011_idx_audit_notes_order_created runInTransaction:true
CREATE INDEX IF NOT EXISTS idx_customer_order_audit_notes_order_created
  ON customer_order_audit_notes (customer_order_id, created_at DESC);

--rollback DROP INDEX IF EXISTS idx_customer_order_audit_notes_order_created;

--changeset warehouse:011_tag
--tagDatabase v011
--rollback empty
