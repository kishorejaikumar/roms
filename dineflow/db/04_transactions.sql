-- =====================================================================
-- DineFlow | UNIT IV : Transactions, ACID, locking, savepoints, isolation levels
-- Run after 01 and 03.   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/04_transactions.sql
-- =====================================================================
SET search_path = dineflow, public, extensions;

-- ---------------------------------------------------------------------
-- 4.1  RULE 3: fn_place_order is ONE atomic transaction.
--   Lock order is ALWAYS:  table row -> menu rows (ascending item_id) -> coupon row.
--   Every caller takes locks in the same order, so two orders can never wait on each
--   other in a circle (no deadlock).  Any error undoes everything:
--   order, lines, stock, coupon counter and payment (Atomicity).
--   p_items example: [{"itemId":4,"qty":2,"note":"less spicy","price":340}]
--   (price is optional; if the client sends it and it is stale, the order is refused)
--   UPI/Card are "paid" at once by a simulated gateway (UPI id starting FAIL, or card 0000, is declined);
--   Cash stays Pending until staff confirm it with fn_confirm_payment().
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_place_order(
  p_customer INT, p_order_type order_type, p_table_id INT, p_items JSONB,
  p_coupon_code TEXT DEFAULT NULL, p_reservation_id INT DEFAULT NULL,
  p_method payment_method DEFAULT 'Cash', p_upi_ref TEXT DEFAULT NULL, p_card_last4 TEXT DEFAULT NULL,
  p_notes TEXT DEFAULT NULL) RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
  v_order INT; v_line INT := 0; r RECORD; m menu_items%ROWTYPE; t restaurant_tables%ROWTYPE;
  v_sub NUMERIC; v_total NUMERIC; v_coupon INT;
BEGIN
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Add at least one dish to the order';
  END IF;
  PERFORM 1 FROM customers WHERE customer_id = p_customer AND is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown or inactive customer'; END IF;

  -- (1) the table row lock: two waiters/browsers on the same table queue up here
  IF p_order_type = 'Dine-in' THEN
    IF p_table_id IS NULL THEN RAISE EXCEPTION 'Choose a table for a dine-in order'; END IF;
    SELECT * INTO t FROM restaurant_tables WHERE table_id = p_table_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Table % does not exist', p_table_id; END IF;
    IF NOT t.is_active THEN RAISE EXCEPTION 'Table % is out of service', t.table_no; END IF;
    IF EXISTS (SELECT 1 FROM orders WHERE table_id = p_table_id AND status NOT IN ('Paid','Cancelled')) THEN
      RAISE EXCEPTION 'Table % already has an active order', t.table_no;
    END IF;
    IF p_reservation_id IS NOT NULL THEN                      -- arriving guest takes their reserved table
      UPDATE table_reservations SET status = 'Seated'
       WHERE reservation_id = p_reservation_id AND customer_id = p_customer AND table_id = p_table_id
         AND status = 'Booked' AND start_time - interval '30 minutes' <= now() AND end_time > now();
      IF NOT FOUND THEN RAISE EXCEPTION 'That reservation is not valid for this table right now'; END IF;
    ELSIF EXISTS (SELECT 1 FROM table_reservations
                   WHERE table_id = p_table_id AND status = 'Booked' AND customer_id <> p_customer
                     AND tstzrange(start_time, end_time) && tstzrange(now(), now() + interval '90 minutes')) THEN
      RAISE EXCEPTION 'Table % is reserved by another guest around this time', t.table_no;
    END IF;
  ELSE
    p_table_id := NULL;                                       -- takeaway has no table
    p_reservation_id := NULL;
  END IF;

  INSERT INTO orders (customer_id, table_id, reservation_id, order_type, notes)
  VALUES (p_customer, p_table_id, p_reservation_id, p_order_type, p_notes) RETURNING order_id INTO v_order;

  -- (2) menu rows: merge duplicate dishes, lock in item_id order, check price + stock, insert, reduce stock
  FOR r IN SELECT (x->>'itemId')::int AS item_id, SUM((x->>'qty')::int) AS qty,
                  MAX(x->>'note') AS note, MAX(x->>'price') AS price
             FROM jsonb_array_elements(p_items) x GROUP BY 1 ORDER BY 1 LOOP
    IF r.qty IS NULL OR r.qty < 1 OR r.qty > 20 THEN RAISE EXCEPTION 'Quantity of each dish must be between 1 and 20'; END IF;
    SELECT * INTO m FROM menu_items WHERE item_id = r.item_id FOR UPDATE;
    IF NOT FOUND OR NOT m.is_active THEN RAISE EXCEPTION 'Menu item % is not available', r.item_id; END IF;
    IF m.is_sold_out OR m.stock_qty = 0 THEN RAISE EXCEPTION '% is sold out', m.name; END IF;
    IF m.stock_qty < r.qty THEN RAISE EXCEPTION 'Only % of % left', m.stock_qty, m.name; END IF;
    IF r.price IS NOT NULL AND r.price::numeric <> m.price THEN
      RAISE EXCEPTION 'The price of % is now Rs %. Please refresh the menu.', m.name, m.price;
    END IF;
    v_line := v_line + 1;
    INSERT INTO order_items (order_id, line_no, item_id, quantity, unit_price, note)
    VALUES (v_order, v_line, m.item_id, r.qty, m.price, left(r.note, 100));
    UPDATE menu_items SET stock_qty = stock_qty - r.qty WHERE item_id = m.item_id;   -- sold-out trigger fires at 0
  END LOOP;

  -- (3) coupon: validated and locked, counter bumped in the same transaction
  IF p_coupon_code IS NOT NULL AND trim(p_coupon_code) <> '' THEN
    SELECT subtotal INTO v_sub FROM orders WHERE order_id = v_order;
    v_coupon := fn_check_coupon(p_coupon_code, p_customer, v_sub);
    UPDATE orders SET coupon_id = v_coupon WHERE order_id = v_order;
    PERFORM fn_recalc_order(v_order);
    UPDATE coupons SET used_count = used_count + 1 WHERE coupon_id = v_coupon;
    INSERT INTO coupon_usage (coupon_id, customer_id, order_id, discount_given)
    SELECT v_coupon, p_customer, v_order, discount_amt FROM orders WHERE order_id = v_order;
  END IF;

  -- (4) payment: if the simulated gateway refuses, EVERYTHING above rolls back
  SELECT total_amt INTO v_total FROM orders WHERE order_id = v_order;
  PERFORM fn_record_payment(v_order, p_method, v_total, p_upi_ref, p_card_last4);
  RETURN v_order;
EXCEPTION
  WHEN unique_violation THEN RAISE EXCEPTION 'That table already has an active order';
  WHEN check_violation  THEN RAISE EXCEPTION 'The order could not be saved (a rule was violated)';
END $$;

-- Shared payment helper: simulated gateway + insert.  UPI/Card -> Success, Cash -> Pending.
CREATE FUNCTION fn_record_payment(p_order INT, p_method payment_method, p_amount NUMERIC,
                                  p_upi_ref TEXT, p_card_last4 TEXT) RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_id INT;
BEGIN
  IF p_method = 'UPI' THEN
    IF p_upi_ref IS NULL OR p_upi_ref !~ '^[A-Za-z0-9._-]{2,}@[A-Za-z0-9]{2,}$' THEN RAISE EXCEPTION 'Enter a valid UPI id such as name@okbank'; END IF;
    IF upper(p_upi_ref) LIKE 'FAIL%' THEN RAISE EXCEPTION 'UPI payment failed, so the order was not placed'; END IF;
    INSERT INTO payments (order_id, method, amount, status, upi_ref) VALUES (p_order, 'UPI', p_amount, 'Success', p_upi_ref) RETURNING payment_id INTO v_id;
  ELSIF p_method = 'Card' THEN
    IF p_card_last4 IS NULL OR p_card_last4 !~ '^[0-9]{4}$' THEN RAISE EXCEPTION 'Enter the last 4 digits of the card'; END IF;
    IF p_card_last4 = '0000' THEN RAISE EXCEPTION 'Card declined by the bank, so the order was not placed'; END IF;
    INSERT INTO payments (order_id, method, amount, status, card_last4) VALUES (p_order, 'Card', p_amount, 'Success', p_card_last4) RETURNING payment_id INTO v_id;
  ELSE
    INSERT INTO payments (order_id, method, amount, status) VALUES (p_order, 'Cash', p_amount, 'Pending') RETURNING payment_id INTO v_id;
  END IF;
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------
-- 4.2  Paying later, splitting the bill (FEATURE E) and confirming cash.
--      p_actor = the customer's id from the token (NULL when an admin acts).
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_assert_order_payable(p_order INT, p_actor INT, OUT o orders) LANGUAGE plpgsql AS $$
BEGIN
  SELECT * INTO o FROM orders WHERE order_id = p_order FOR UPDATE;           -- one payer at a time
  IF NOT FOUND THEN RAISE EXCEPTION 'Order % does not exist', p_order; END IF;
  IF p_actor IS NOT NULL AND o.customer_id <> p_actor THEN RAISE EXCEPTION 'This is not your order'; END IF;
  IF o.status IN ('Paid','Cancelled') THEN RAISE EXCEPTION 'Order is already %', o.status; END IF;
END $$;

CREATE FUNCTION fn_pay_order(p_order INT, p_actor INT, p_method payment_method, p_upi_ref TEXT DEFAULT NULL, p_card_last4 TEXT DEFAULT NULL)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE o orders; v_paid NUMERIC;
BEGIN
  o := fn_assert_order_payable(p_order, p_actor);
  IF EXISTS (SELECT 1 FROM order_splits WHERE order_id = p_order) THEN RAISE EXCEPTION 'This bill is split; pay each share separately'; END IF;
  UPDATE payments SET status = 'Failed' WHERE order_id = p_order AND status = 'Pending';   -- replace a pending cash promise
  SELECT COALESCE(SUM(amount), 0) INTO v_paid FROM payments WHERE order_id = p_order AND status = 'Success';
  IF o.total_amt - v_paid <= 0 THEN RAISE EXCEPTION 'Nothing is due on this order'; END IF;
  RETURN fn_record_payment(p_order, p_method, o.total_amt - v_paid, p_upi_ref, p_card_last4);
END $$;

CREATE FUNCTION fn_split_bill(p_order INT, p_actor INT, p_names TEXT[]) RETURNS INT LANGUAGE plpgsql AS $$
DECLARE o orders; n INT := COALESCE(array_length(p_names, 1), 0); v_each NUMERIC; i INT;
BEGIN
  IF n < 2 OR n > 10 THEN RAISE EXCEPTION 'A bill can be split between 2 and 10 diners'; END IF;
  o := fn_assert_order_payable(p_order, p_actor);
  IF o.total_amt <= 0 THEN RAISE EXCEPTION 'Nothing to split'; END IF;
  IF EXISTS (SELECT 1 FROM order_splits WHERE order_id = p_order)
     OR EXISTS (SELECT 1 FROM payments WHERE order_id = p_order AND status = 'Success') THEN
    RAISE EXCEPTION 'This bill already has payments or a split';
  END IF;
  UPDATE payments SET status = 'Failed' WHERE order_id = p_order AND status = 'Pending';
  v_each := ROUND(o.total_amt / n, 2);
  FOR i IN 1..n LOOP
    INSERT INTO order_splits (order_id, split_no, payer_name, amount)
    VALUES (p_order, i, left(trim(p_names[i]), 60), CASE WHEN i < n THEN v_each ELSE o.total_amt - v_each * (n - 1) END);
  END LOOP;                                                   -- the deferred trigger checks the sum at COMMIT
  RETURN n;
END $$;

CREATE FUNCTION fn_pay_split(p_order INT, p_split_no INT, p_actor INT, p_method payment_method,
                             p_upi_ref TEXT DEFAULT NULL, p_card_last4 TEXT DEFAULT NULL) RETURNS INT LANGUAGE plpgsql AS $$
DECLARE o orders; s order_splits%ROWTYPE; v_pay INT;
BEGIN
  o := fn_assert_order_payable(p_order, p_actor);
  SELECT * INTO s FROM order_splits WHERE order_id = p_order AND split_no = p_split_no FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No such share on this bill'; END IF;
  IF s.payment_id IS NOT NULL THEN RAISE EXCEPTION 'This share is already paid'; END IF;
  v_pay := fn_record_payment(p_order, p_method, s.amount, p_upi_ref, p_card_last4);
  UPDATE order_splits SET payment_id = v_pay WHERE order_id = p_order AND split_no = p_split_no;
  RETURN v_pay;
END $$;

CREATE FUNCTION fn_confirm_payment(p_payment INT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  UPDATE payments SET status = 'Success' WHERE payment_id = p_payment AND status = 'Pending';
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment % is not pending', p_payment; END IF;
END $$;

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
