--liquibase formatted sql

--changeset warehouse:012_idx_audit_notes_created_brin runInTransaction:true
CREATE INDEX IF NOT EXISTS brin_customer_order_audit_notes_created_at
  ON customer_order_audit_notes USING BRIN (created_at);

--rollback DROP INDEX IF EXISTS brin_customer_order_audit_notes_created_at;

--changeset warehouse:012_tag
--tagDatabase v012
--rollback empty
