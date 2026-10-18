-- =====================================================================
-- DineFlow | UNIT V (PART A): the permanent indexes the website needs.
-- Run this first. Safe to re-run (IF NOT EXISTS). The whole script is ONE transaction,
-- and SET LOCAL pins the schema inside it, so the Supabase editor cannot lose the search_path.
-- =====================================================================
BEGIN;
  SET LOCAL search_path = dineflow, public, extensions;

  -- (idx_orders_status and idx_orders_customer were created in 01; these add the new shapes.)
  CREATE INDEX IF NOT EXISTS idx_orders_customer_recent ON dineflow.orders (customer_id, created_at DESC);   -- "my orders"
  CREATE INDEX IF NOT EXISTS idx_orders_live            ON dineflow.orders (created_at) WHERE status IN ('Placed','Preparing','Served','Billed');  -- kitchen/admin
  CREATE INDEX IF NOT EXISTS idx_orders_paid_time       ON dineflow.orders (updated_at) WHERE status = 'Paid';     -- settlement and 7-day report
  CREATE INDEX IF NOT EXISTS idx_payments_status        ON dineflow.payments (status) WHERE status = 'Pending';   -- cash awaiting confirmation
COMMIT;

SELECT indexname FROM pg_indexes
 WHERE schemaname = 'dineflow' AND tablename IN ('orders','payments') ORDER BY 1;