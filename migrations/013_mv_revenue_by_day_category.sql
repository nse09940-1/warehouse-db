--liquibase formatted sql

--changeset warehouse:013_mv_revenue_by_day_category runInTransaction:true splitStatements:false rollbackSplitStatements:false
DROP MATERIALIZED VIEW IF EXISTS mv_revenue_by_day_category;

CREATE MATERIALIZED VIEW mv_revenue_by_day_category AS
WITH audit_counts AS (
  SELECT
    customer_order_id,
    count(*) AS audit_note_count
  FROM customer_order_audit_notes
  GROUP BY customer_order_id
),
order_category_revenue AS (
  SELECT
    co.customer_order_id,
    date_trunc('day', co.created_at)::date AS sales_day,
    pc.category_name,
    sum(coi.ordered_quantity * coi.sale_price) AS revenue
  FROM customer_orders co
  JOIN customer_order_items coi ON coi.customer_order_id = co.customer_order_id
  JOIN products p ON p.product_id = coi.product_id
  JOIN product_categories pc ON pc.category_id = p.category_id
  GROUP BY co.customer_order_id, sales_day, pc.category_name
)
SELECT
  ocr.sales_day,
  ocr.category_name,
  count(DISTINCT ocr.customer_order_id) AS order_count,
  sum(ocr.revenue)::numeric(18,2) AS revenue,
  sum(COALESCE(audit_counts.audit_note_count, 0))::bigint AS audit_note_count
FROM order_category_revenue ocr
LEFT JOIN audit_counts ON audit_counts.customer_order_id = ocr.customer_order_id
GROUP BY ocr.sales_day, ocr.category_name;

CREATE UNIQUE INDEX IF NOT EXISTS uq_mv_revenue_by_day_category_day_category
  ON mv_revenue_by_day_category (sales_day, category_name);

CREATE INDEX IF NOT EXISTS idx_mv_revenue_by_day_category_revenue
  ON mv_revenue_by_day_category (revenue DESC);

--rollback DROP MATERIALIZED VIEW IF EXISTS mv_revenue_by_day_category;

--changeset warehouse:013_tag
--tagDatabase v013
--rollback empty
