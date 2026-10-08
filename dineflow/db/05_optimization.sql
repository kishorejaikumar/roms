-- =====================================================================
-- DineFlow | UNIT V : Query optimisation   (run with psql so the plans are printed)
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/05_optimization.sql
-- The benchmark runs inside BEGIN ... ROLLBACK, so the 50,000 generated orders and the
-- experimental indexes vanish afterwards.  It creates its own helper rows (ids 900000+),
-- so it works on an empty or a seeded database.
-- =====================================================================
SET search_path = dineflow, public, extensions;

BEGIN;
  ALTER TABLE orders      DISABLE TRIGGER USER;      -- bulk load: skip audit/recalc triggers (undone by ROLLBACK)
  ALTER TABLE order_items DISABLE TRIGGER USER;

  -- helper customers, one category and three dishes (explicit ids so the queries below can use literals)
  INSERT INTO customers (customer_id, full_name, email, phone, password_hash) OVERRIDING SYSTEM VALUE
  SELECT 900000 + g, 'Bench Customer ' || g, 'bench' || g || '@example.in', '9000000000', 'x' FROM generate_series(1, 500) g;
  INSERT INTO categories (category_id, name) OVERRIDING SYSTEM VALUE VALUES (900001, 'Bench');
  INSERT INTO menu_items (item_id, category_id, name, price, stock_qty) OVERRIDING SYSTEM VALUE
  SELECT 900000 + g, 900001, 'Bench Dish ' || g, 100 * g, 1000 FROM generate_series(1, 3) g;

  -- 50,000 takeaway orders over 30 days; 99.5% Paid, 0.5% still Preparing (the rare rows kitchens look for)
  INSERT INTO orders (customer_id, order_type, status, created_at, updated_at, subtotal, tax_amt, total_amt)
  SELECT 900001 + (g % 500), 'Takeaway',
         CASE WHEN g % 200 = 0 THEN 'Preparing'::order_status ELSE 'Paid'::order_status END,
         now() - (g * interval '51 seconds'), now() - (g * interval '51 seconds'),
         100 + g % 900, ROUND((100 + g % 900) * 0.05, 2), (100 + g % 900) + ROUND((100 + g % 900) * 0.05, 2)
    FROM generate_series(1, 50000) g;
  INSERT INTO order_items (order_id, line_no, item_id, quantity, unit_price)
  SELECT o.order_id, l, 900000 + l, 1 + o.order_id % 3, 100 * l
    FROM orders o CROSS JOIN generate_series(1, 3) l WHERE o.customer_id >= 900001;
  -- (indexes created by 01 exist already; DROP them to measure the "before" case)
  DROP INDEX IF EXISTS idx_orders_status, idx_orders_customer, idx_orders_customer_recent, idx_orders_live, idx_order_items_order;
  ANALYZE orders; ANALYZE order_items;

  SELECT COUNT(*) AS orders_in_table, COUNT(*) FILTER (WHERE status = 'Preparing') AS preparing_rows FROM orders;

  ---------------------------------------------------------------------------------------------
  -- 5.1  EXPLAIN (plan only, nothing executed) versus EXPLAIN ANALYZE (executed, real times)
  ---------------------------------------------------------------------------------------------
  SELECT '== 5.1 EXPLAIN: estimated plan only (no execution)' AS step;
  EXPLAIN SELECT order_id FROM orders WHERE status = 'Preparing' AND customer_id = 900201;

  SELECT '== 5.1 EXPLAIN ANALYZE BEFORE any index: expect Seq Scan' AS step;
  EXPLAIN (ANALYZE, BUFFERS) SELECT order_id, created_at FROM orders WHERE status = 'Preparing' AND customer_id = 900201;

  ---------------------------------------------------------------------------------------------
  -- 5.2  Single-column B-tree index
  ---------------------------------------------------------------------------------------------
  CREATE INDEX idx_orders_status ON orders (status);
  ANALYZE orders;
  SELECT '== 5.2 AFTER single-column index on status' AS step;
  EXPLAIN (ANALYZE, BUFFERS) SELECT order_id, created_at FROM orders WHERE status = 'Preparing' AND customer_id = 900201;

  ---------------------------------------------------------------------------------------------
  -- 5.3  Composite index (customer_id, created_at DESC): "my recent orders" query
  ---------------------------------------------------------------------------------------------
  SELECT '== 5.3 my-orders query BEFORE composite index' AS step;
  EXPLAIN (ANALYZE) SELECT order_id, total_amt FROM orders WHERE customer_id = 900201 ORDER BY created_at DESC LIMIT 10;
  CREATE INDEX idx_orders_customer_recent ON orders (customer_id, created_at DESC);
  ANALYZE orders;
  SELECT '== 5.3 my-orders query AFTER composite index (no separate sort step)' AS step;
  EXPLAIN (ANALYZE) SELECT order_id, total_amt FROM orders WHERE customer_id = 900201 ORDER BY created_at DESC LIMIT 10;

  ---------------------------------------------------------------------------------------------
  -- 5.4  Partial index: only LIVE orders, which is what the kitchen display reads
  ---------------------------------------------------------------------------------------------
  SELECT '== 5.4 kitchen query using the full status index' AS step;
  EXPLAIN (ANALYZE) SELECT order_id FROM orders WHERE status IN ('Placed','Preparing') ORDER BY created_at;
  CREATE INDEX idx_orders_live ON orders (created_at) WHERE status IN ('Placed','Preparing','Served','Billed');
  ANALYZE orders;
  SELECT '== 5.4 kitchen query using the partial index (tiny index, only live rows)' AS step;
  EXPLAIN (ANALYZE) SELECT order_id FROM orders WHERE status IN ('Placed','Preparing') ORDER BY created_at;
  SELECT indexname, pg_size_pretty(pg_relation_size(indexname::regclass)) AS size
    FROM pg_indexes WHERE schemaname = 'dineflow' AND tablename = 'orders' AND indexname IN ('idx_orders_status','idx_orders_live') ORDER BY 1;

  ---------------------------------------------------------------------------------------------
  -- 5.5  JOIN METHODS: let the planner choose, then force each method and compare times
  ---------------------------------------------------------------------------------------------
  CREATE INDEX idx_order_items_order ON order_items (order_id);   -- helps nested loop (PK already covers it; shown for clarity)
  ANALYZE order_items;
  SELECT '== 5.5a planner choice' AS step;
  EXPLAIN (ANALYZE) SELECT m.name, SUM(oi.line_total) FROM orders o JOIN order_items oi ON oi.order_id = o.order_id
    JOIN menu_items m ON m.item_id = oi.item_id WHERE o.created_at > now() - interval '2 days' GROUP BY m.name;
  SET LOCAL enable_hashjoin = off; SET LOCAL enable_mergejoin = off;
  SELECT '== 5.5b forced NESTED LOOP' AS step;
  EXPLAIN (ANALYZE) SELECT m.name, SUM(oi.line_total) FROM orders o JOIN order_items oi ON oi.order_id = o.order_id
    JOIN menu_items m ON m.item_id = oi.item_id WHERE o.created_at > now() - interval '2 days' GROUP BY m.name;
  SET LOCAL enable_hashjoin = off; SET LOCAL enable_nestloop = off; SET LOCAL enable_mergejoin = on;
  SELECT '== 5.5c forced MERGE JOIN' AS step;
  EXPLAIN (ANALYZE) SELECT m.name, SUM(oi.line_total) FROM orders o JOIN order_items oi ON oi.order_id = o.order_id
    JOIN menu_items m ON m.item_id = oi.item_id WHERE o.created_at > now() - interval '2 days' GROUP BY m.name;
  SET LOCAL enable_hashjoin = on; SET LOCAL enable_nestloop = on;
  SELECT '== 5.5d forced HASH JOIN' AS step;
  SET LOCAL enable_mergejoin = off; SET LOCAL enable_nestloop = off;
  EXPLAIN (ANALYZE) SELECT m.name, SUM(oi.line_total) FROM orders o JOIN order_items oi ON oi.order_id = o.order_id
    JOIN menu_items m ON m.item_id = oi.item_id WHERE o.created_at > now() - interval '2 days' GROUP BY m.name;
ROLLBACK;

-- ---------------------------------------------------------------------
-- PERMANENT indexes for the live schema (the ones the application queries need).
-- (idx_orders_status and idx_orders_customer were created in 01; these add the new shapes.)
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_orders_customer_recent ON orders (customer_id, created_at DESC);          -- "my orders"
CREATE INDEX IF NOT EXISTS idx_orders_live            ON orders (created_at) WHERE status IN ('Placed','Preparing','Served','Billed');  -- kitchen/admin
CREATE INDEX IF NOT EXISTS idx_orders_paid_time       ON orders (updated_at) WHERE status = 'Paid';           -- settlement and 7-day report (range scans)
CREATE INDEX IF NOT EXISTS idx_payments_status        ON payments (status) WHERE status = 'Pending';         -- cash awaiting confirmation
SELECT indexname FROM pg_indexes WHERE schemaname = 'dineflow' AND tablename IN ('orders','payments') ORDER BY 1;
