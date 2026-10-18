-- =====================================================================
-- DineFlow | UNIT IV (PART B): demo of savepoints, rollback on a declined card, isolation levels,
-- and the two-session locking scripts.  Run AFTER 04_transactions.sql, as its own query.
-- Self-cleaning: it creates its own rows and ends with ROLLBACK, so your data is untouched.
-- In psql the SELECT results of every step are printed; the Supabase editor shows only the LAST
-- result of a run, so use psql (or run the steps one at a time) for screenshots.
-- =====================================================================
SET search_path = dineflow, public, extensions;

-- ---------------------------------------------------------------------
-- 4.3  Runnable demo (self-cleaning: creates its own rows, then ROLLBACK).
--      Shows BEGIN, SAVEPOINT, ROLLBACK TO SAVEPOINT, failed payment rollback, isolation level.
-- ---------------------------------------------------------------------
BEGIN;
  SELECT current_setting('transaction_isolation') AS isolation_level;
  INSERT INTO customers (customer_id, full_name, email, phone, password_hash) OVERRIDING SYSTEM VALUE
    VALUES (990001, 'Demo Guest', 'demo.guest@example.in', '9000000001', 'x');
  INSERT INTO restaurant_tables (table_id, table_no, capacity) OVERRIDING SYSTEM VALUE VALUES (990001, 'D01', 4);
  INSERT INTO categories (category_id, name) OVERRIDING SYSTEM VALUE VALUES (990001, 'Demo');
  INSERT INTO menu_items (item_id, category_id, name, price, stock_qty) OVERRIDING SYSTEM VALUE
    VALUES (990001, 990001, 'Demo Thali', 200, 5);

  SAVEPOINT before_order;
  SELECT fn_place_order(990001, 'Dine-in', 990001, '[{"itemId":990001,"qty":2}]', NULL, NULL, 'Cash') AS new_order_id;
  SELECT 'after order' AS step, stock_qty FROM menu_items WHERE item_id = 990001;          -- 3

  ROLLBACK TO SAVEPOINT before_order;                                                       -- undo the whole order
  SELECT 'after ROLLBACK TO SAVEPOINT' AS step, stock_qty,
         (SELECT COUNT(*) FROM orders WHERE customer_id = 990001) AS orders_left
    FROM menu_items WHERE item_id = 990001;                                                 -- 5 and 0

  DO $demo$ BEGIN                                           -- failed card: the whole order rolls back
    PERFORM fn_place_order(990001, 'Dine-in', 990001, '[{"itemId":990001,"qty":1}]', NULL, NULL, 'Card', NULL, '0000');
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM;
  END $demo$;
  SELECT 'after declined card' AS step, stock_qty,
         (SELECT COUNT(*) FROM orders WHERE customer_id = 990001) AS orders_left
    FROM menu_items WHERE item_id = 990001;                                                 -- still 5 and 0
ROLLBACK;

BEGIN ISOLATION LEVEL REPEATABLE READ;                      -- snapshot isolation: the whole tx sees one snapshot
  SELECT current_setting('transaction_isolation') AS isolation_level, COUNT(*) AS menu_items_seen FROM menu_items;
COMMIT;

-- ---------------------------------------------------------------------
-- 4.4  TWO-SESSION DEMOS (open two psql windows; run the steps in the order shown)
--
--  A. Same TABLE from two browsers (row lock)
--     Session A                                      | Session B
--     BEGIN;                                         |
--     SELECT * FROM restaurant_tables                |
--      WHERE table_no='T09' FOR UPDATE;              |
--                                                    | BEGIN;
--                                                    | SELECT fn_place_order(2,'Dine-in',9,
--                                                    |   '[{"itemId":1,"qty":1}]');   -- BLOCKS
--     SELECT fn_place_order(1,'Dine-in',9,           |
--       '[{"itemId":1,"qty":1}]');                   |
--     COMMIT;                                        | -- unblocks: ERROR Table T09 already has an active order
--                                                    | ROLLBACK;
--
--  B. The LAST dish (Rasmalai has stock 1 after seeding): both sessions call
--     fn_place_order with {"itemId":19,"qty":1} on different tables / takeaway.
--     The menu row is locked FOR UPDATE: the first commits, the second waits, then reads
--     stock 0 and fails with "Rasmalai is sold out".
--
--  C. Deadlock-safe ordering: Session A orders items [3,1], Session B orders [1,3].
--     Both sort the lines by item_id, so both lock 1 then 3: B waits for A, no deadlock.
--
--  D. Isolation levels (READ COMMITTED is the PostgreSQL default)
--     Session A: BEGIN ISOLATION LEVEL READ COMMITTED; SELECT stock_qty FROM menu_items WHERE item_id=1;
--     Session B: UPDATE menu_items SET stock_qty = stock_qty - 1 WHERE item_id=1;  (autocommit)
--     Session A: SELECT stock_qty ...   -> sees the NEW value (non-repeatable read allowed)
--     Repeat with REPEATABLE READ in A -> A keeps seeing the OLD value; an UPDATE of that row in A
--     then fails with "could not serialize access due to concurrent update" (SQLSTATE 40001).
--     SERIALIZABLE additionally detects write-skew; the API retries on 40001.
--
--  E. Fail fast / skip locked variants
--     SELECT * FROM orders WHERE order_id = 10 FOR UPDATE NOWAIT;       -- error 55P03 if another session holds it
--     SELECT * FROM orders WHERE status='Placed' FOR UPDATE SKIP LOCKED LIMIT 1;  -- two cooks never take the same ticket
-- ---------------------------------------------------------------------
SELECT proname AS transaction_functions FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'dineflow' AND proname IN ('fn_place_order','fn_pay_order','fn_split_bill','fn_pay_split','fn_confirm_payment') ORDER BY 1;
