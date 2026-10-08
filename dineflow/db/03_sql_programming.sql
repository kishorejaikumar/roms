-- =====================================================================
-- DineFlow | 24CS303 DBMS | STAGE 2 : UNIT II (SQL programming)
-- Run AFTER 01_schema_er.sql and BEFORE 06_seed_data.sql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/03_sql_programming.sql
--
-- Contents
--   2.1  Session context helpers (who is acting: role + user id)
--   2.2  Authentication in the database (bcrypt via pgcrypto)       RULE 5
--   2.3  Coupons: discount maths and validation                     FEATURE C
--   2.4  Order totals trigger: total = subtotal - discount + 5% GST RULE 1
--   2.5  Status-flow trigger + audit trail + cancel side effects    RULE 2, FEATURE G
--   2.6  Payment triggers (auto Billed -> Paid)
--   2.7  Reviews trigger                                            RULE 4
--   2.8  Reservations: helper functions + trigger                   FEATURE B
--   2.9  Low-stock trigger, implicit cursors, restock               FEATURE D
--   2.10 Bill-split check (deferred constraint trigger)             FEATURE E
--   2.11 Views (+ a "synonym")                                      FEATURE F, G, H
--   2.12 Dynamic SQL report function
--   2.13 Explicit-cursor end-of-day procedure                       RULE 6
-- =====================================================================
SET search_path = dineflow, public, extensions;

-- ---------------------------------------------------------------------
-- 2.1  Session context.  The backend sets these inside each transaction:
--        SELECT set_config('dineflow.role','kitchen',true), set_config('dineflow.user_id','7',true);
--      Triggers read them, so the database knows WHO is acting. If nothing is
--      set the actor is 'system' (a trigger or a psql session).
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_ctx_role() RETURNS TEXT LANGUAGE sql STABLE AS $$
  SELECT coalesce(nullif(current_setting('dineflow.role', true), ''), 'system')
$$;
CREATE FUNCTION fn_ctx_user() RETURNS INT LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('dineflow.user_id', true), '')::int
$$;

-- ---------------------------------------------------------------------
-- 2.2  RULE 5: passwords are hashed INSIDE the database. The backend never
--      sees or stores a hash; it only calls these functions.
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_register_customer(p_name TEXT, p_email TEXT, p_phone TEXT, p_password TEXT)
RETURNS INT LANGUAGE plpgsql SET search_path = dineflow, public, extensions AS $$
DECLARE v_id INT;
BEGIN
  IF p_password IS NULL OR length(p_password) < 8 THEN
    RAISE EXCEPTION 'Password must be at least 8 characters';
  END IF;
  INSERT INTO customers (full_name, email, phone, password_hash)
  VALUES (trim(p_name), trim(p_email), p_phone, crypt(p_password, gen_salt('bf', 10)))
  RETURNING customer_id INTO v_id;
  RETURN v_id;
EXCEPTION                                              -- UNIT II: exception handling
  WHEN unique_violation THEN RAISE EXCEPTION 'This email is already registered';
  WHEN check_violation  THEN RAISE EXCEPTION 'Please enter a valid name, email and 10-digit phone number';
END $$;

-- Returns one row on success, no rows on a wrong email/password (same answer for both: no user enumeration).
CREATE FUNCTION fn_login_customer(p_email TEXT, p_password TEXT)
RETURNS TABLE (customer_id INT, full_name TEXT) LANGUAGE sql STABLE SET search_path = dineflow, public, extensions AS $$
  SELECT c.customer_id, c.full_name::text FROM customers c
   WHERE lower(c.email) = lower(trim(p_email)) AND c.is_active
     AND c.password_hash = crypt(p_password, c.password_hash)
$$;

CREATE FUNCTION fn_login_staff(p_email TEXT, p_password TEXT)
RETURNS TABLE (staff_id INT, full_name TEXT, role TEXT) LANGUAGE sql STABLE SET search_path = dineflow, public, extensions AS $$
  SELECT s.staff_id, s.full_name::text, s.role::text FROM staff s
   WHERE lower(s.email) = lower(trim(p_email)) AND s.is_active
     AND s.password_hash = crypt(p_password, s.password_hash)
$$;

-- ---------------------------------------------------------------------
-- 2.3  FEATURE C: coupons
--      fn_coupon_discount : pure maths (used by the totals trigger)
--      fn_check_coupon    : validates a code for a customer and LOCKS the coupon row
--                           (FOR UPDATE) so two buyers cannot both take the last use.
--                           place_order (Stage 3) increments used_count in the same transaction.
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_coupon_discount(p_coupon INT, p_subtotal NUMERIC) RETURNS NUMERIC
LANGUAGE plpgsql STABLE AS $$
DECLARE c coupons%ROWTYPE; v NUMERIC;
BEGIN
  SELECT * INTO c FROM coupons WHERE coupon_id = p_coupon;
  IF NOT FOUND OR p_subtotal < c.min_order_amount THEN RETURN 0; END IF;
  IF c.discount_type = 'PERCENT' THEN
    v := ROUND(p_subtotal * c.discount_value / 100, 2);
    IF c.max_discount IS NOT NULL THEN v := LEAST(v, c.max_discount); END IF;
  ELSE
    v := c.discount_value;
  END IF;
  RETURN LEAST(v, p_subtotal);                         -- never more than the bill
END $$;

CREATE FUNCTION fn_check_coupon(p_code TEXT, p_customer INT, p_subtotal NUMERIC) RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE c coupons%ROWTYPE; v_used INT;
BEGIN
  SELECT * INTO c FROM coupons WHERE code = upper(trim(p_code)) FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Coupon code not found'; END IF;
  IF NOT c.is_active THEN RAISE EXCEPTION 'This coupon is not active'; END IF;
  IF now() < c.valid_from OR now() > c.valid_to THEN RAISE EXCEPTION 'This coupon has expired or is not valid yet'; END IF;
  IF c.used_count >= c.max_total_uses THEN RAISE EXCEPTION 'This coupon has been fully redeemed'; END IF;
  IF p_subtotal < c.min_order_amount THEN
    RAISE EXCEPTION 'Minimum order of Rs % is needed for this coupon', c.min_order_amount;
  END IF;
  SELECT COUNT(*) INTO v_used FROM coupon_usage WHERE coupon_id = c.coupon_id AND customer_id = p_customer;
  IF v_used >= c.per_customer_limit THEN RAISE EXCEPTION 'You have already used this coupon the allowed number of times'; END IF;
  RETURN c.coupon_id;
END $$;

-- ---------------------------------------------------------------------
-- 2.4  RULE 1: order total is ALWAYS recomputed by the database.
--      total = subtotal - coupon discount + 5% GST on the discounted amount.
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_recalc_order(p_order INT) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE v_coupon INT; v_sub NUMERIC(10,2); v_disc NUMERIC(10,2); v_tax NUMERIC(10,2);
BEGIN
  SELECT coupon_id INTO v_coupon FROM orders WHERE order_id = p_order;
  IF NOT FOUND THEN RETURN; END IF;
  SELECT COALESCE(SUM(line_total), 0) INTO v_sub FROM order_items WHERE order_id = p_order;
  v_disc := CASE WHEN v_coupon IS NULL THEN 0 ELSE fn_coupon_discount(v_coupon, v_sub) END;
  v_tax  := ROUND((v_sub - v_disc) * 0.05, 2);
  UPDATE orders SET subtotal = v_sub, discount_amt = v_disc, tax_amt = v_tax,
                    total_amt = v_sub - v_disc + v_tax
   WHERE order_id = p_order;
END $$;

CREATE FUNCTION fn_order_items_recalc() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM fn_recalc_order(CASE WHEN TG_OP = 'DELETE' THEN OLD.order_id ELSE NEW.order_id END);
  RETURN NULL;
END $$;
CREATE TRIGGER trg_order_items_recalc AFTER INSERT OR UPDATE OR DELETE ON order_items
  FOR EACH ROW EXECUTE FUNCTION fn_order_items_recalc();

-- Guard: lines can only be added to a Placed order, for a dish that is on sale,
-- at the CURRENT menu price (the snapshot in unit_price must be honest).
CREATE FUNCTION fn_order_items_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_status order_status; m menu_items%ROWTYPE;
BEGIN
  SELECT status INTO v_status FROM orders WHERE order_id = NEW.order_id;
  IF v_status IS DISTINCT FROM 'Placed' THEN
    RAISE EXCEPTION 'Items can only be added while the order is Placed (it is %)', v_status;
  END IF;
  SELECT * INTO m FROM menu_items WHERE item_id = NEW.item_id;
  IF NOT FOUND OR NOT m.is_active THEN RAISE EXCEPTION 'Menu item % is not on the menu', NEW.item_id; END IF;
  IF m.is_sold_out THEN RAISE EXCEPTION '% is sold out', m.name; END IF;
  IF NEW.unit_price <> m.price THEN RAISE EXCEPTION 'Price of % has changed to Rs %', m.name, m.price; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_order_items_guard BEFORE INSERT ON order_items
  FOR EACH ROW EXECUTE FUNCTION fn_order_items_guard();

-- ---------------------------------------------------------------------
-- 2.5  RULE 2: status moves ONLY along status_flow, by an allowed role.
--      Every change is written to audit_log (feature G).
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_orders_status_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_roles TEXT[]; v_role TEXT := fn_ctx_role(); v_uid INT := fn_ctx_user(); v_paid NUMERIC;
BEGIN
  SELECT allowed_roles INTO v_roles FROM status_flow
   WHERE from_status = OLD.status AND to_status = NEW.status;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Illegal status change: % -> %', OLD.status, NEW.status;
  END IF;
  IF NOT (v_role = ANY (v_roles)) THEN
    RAISE EXCEPTION 'Role % may not move an order from % to %', v_role, OLD.status, NEW.status;
  END IF;
  IF v_role = 'customer' AND v_uid IS DISTINCT FROM OLD.customer_id THEN
    RAISE EXCEPTION 'Only the customer who placed the order (or an admin) can cancel it';
  END IF;
  IF NEW.status IN ('Preparing','Billed') AND NOT EXISTS (SELECT 1 FROM order_items WHERE order_id = NEW.order_id) THEN
    RAISE EXCEPTION 'An order with no items cannot move to %', NEW.status;
  END IF;
  IF NEW.status = 'Paid' THEN
    SELECT COALESCE(SUM(amount), 0) INTO v_paid FROM payments WHERE order_id = NEW.order_id AND status = 'Success';
    IF v_paid < NEW.total_amt THEN
      RAISE EXCEPTION 'Bill not fully paid: paid Rs % of Rs %', v_paid, NEW.total_amt;
    END IF;
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END $$;
CREATE TRIGGER trg_orders_status_guard BEFORE UPDATE ON orders
  FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION fn_orders_status_guard();

-- Audit trail for every status change
CREATE FUNCTION fn_orders_status_audit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO audit_log (table_name, record_id, action, old_data, new_data, changed_by)
  VALUES ('orders', NEW.order_id, 'STATUS',
          jsonb_build_object('status', OLD.status), jsonb_build_object('status', NEW.status),
          fn_ctx_role() || COALESCE(':' || fn_ctx_user(), ''));
  RETURN NULL;
END $$;
CREATE TRIGGER trg_orders_status_audit AFTER UPDATE ON orders
  FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION fn_orders_status_audit();

-- Generic row audit (INSERT/UPDATE/DELETE as JSONB). TG_ARGV[0] = primary-key column name.
CREATE FUNCTION fn_audit_generic() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_id INT;
BEGIN
  v_id := (to_jsonb(CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END) ->> TG_ARGV[0])::int;
  INSERT INTO audit_log (table_name, record_id, action, old_data, new_data, changed_by)
  VALUES (TG_TABLE_NAME, v_id, TG_OP,
          CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END,
          CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) END,
          fn_ctx_role() || COALESCE(':' || fn_ctx_user(), ''));
  RETURN NULL;
END $$;
CREATE TRIGGER trg_audit_orders_ins   AFTER INSERT ON orders   FOR EACH ROW EXECUTE FUNCTION fn_audit_generic('order_id');
CREATE TRIGGER trg_audit_payments     AFTER INSERT OR UPDATE ON payments FOR EACH ROW EXECUTE FUNCTION fn_audit_generic('payment_id');
CREATE TRIGGER trg_audit_menu_price   AFTER UPDATE ON menu_items
  FOR EACH ROW WHEN (OLD.price IS DISTINCT FROM NEW.price) EXECUTE FUNCTION fn_audit_generic('item_id');

-- Cancelling an order undoes its side effects in the SAME transaction:
-- stock goes back (locked in item_id order, deadlock-safe), the coupon use is released,
-- successful payments are marked Refunded and pending ones Failed.
CREATE FUNCTION fn_orders_on_cancel() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE r RECORD; v_n INT;
BEGIN
  FOR r IN SELECT item_id, quantity FROM order_items WHERE order_id = NEW.order_id ORDER BY item_id LOOP
    UPDATE menu_items SET stock_qty = stock_qty + r.quantity WHERE item_id = r.item_id;
  END LOOP;
  IF NEW.coupon_id IS NOT NULL THEN
    DELETE FROM coupon_usage WHERE order_id = NEW.order_id;
    GET DIAGNOSTICS v_n = ROW_COUNT;                           -- implicit cursor attribute
    IF v_n > 0 THEN UPDATE coupons SET used_count = used_count - 1 WHERE coupon_id = NEW.coupon_id; END IF;
  END IF;
  UPDATE payments SET status = 'Refunded' WHERE order_id = NEW.order_id AND status = 'Success';
  UPDATE payments SET status = 'Failed'   WHERE order_id = NEW.order_id AND status = 'Pending';
  RETURN NULL;
END $$;
CREATE TRIGGER trg_orders_on_cancel AFTER UPDATE ON orders
  FOR EACH ROW WHEN (NEW.status = 'Cancelled' AND OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION fn_orders_on_cancel();

-- Friendly wrapper used by the API (and by you in psql). Shows exception handling.
CREATE FUNCTION fn_cancel_order(p_order_id INT, p_role TEXT, p_user_id INT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM orders WHERE order_id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order % does not exist', p_order_id; END IF;
  BEGIN
    PERFORM set_config('dineflow.role', p_role, true);
    PERFORM set_config('dineflow.user_id', COALESCE(p_user_id::text, ''), true);
    UPDATE orders SET status = 'Cancelled' WHERE order_id = p_order_id;
  EXCEPTION WHEN raise_exception THEN
    RAISE EXCEPTION 'Cannot cancel order %: %', p_order_id, SQLERRM;
  END;
END $$;

-- ---------------------------------------------------------------------
-- 2.6  Payments
--      BEFORE: stamp paid_at, refuse payments on closed orders or above the bill.
--      AFTER : when successful payments cover the bill, Served -> Billed -> Paid.
--      Also runs when an order becomes Served after it was prepaid.
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_payments_before() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_status order_status; v_total NUMERIC; v_committed NUMERIC;
BEGIN
  IF NEW.status = 'Success' AND NEW.paid_at IS NULL THEN NEW.paid_at := now(); END IF;
  IF TG_OP = 'INSERT' THEN
    SELECT status, total_amt INTO v_status, v_total FROM orders WHERE order_id = NEW.order_id;
    IF v_status IN ('Paid','Cancelled') THEN RAISE EXCEPTION 'Order is already %', v_status; END IF;
    SELECT COALESCE(SUM(amount), 0) INTO v_committed FROM payments
     WHERE order_id = NEW.order_id AND status IN ('Pending','Success');
    IF v_committed + NEW.amount > v_total THEN
      RAISE EXCEPTION 'Payment of Rs % exceeds the amount still due (Rs %)', NEW.amount, v_total - v_committed;
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_payments_before BEFORE INSERT OR UPDATE ON payments
  FOR EACH ROW EXECUTE FUNCTION fn_payments_before();

CREATE FUNCTION fn_try_close_order(p_order INT) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE v_status order_status; v_total NUMERIC; v_paid NUMERIC; v_prev TEXT;
BEGIN
  SELECT status, total_amt INTO v_status, v_total FROM orders WHERE order_id = p_order FOR UPDATE;
  IF NOT FOUND OR v_total <= 0 OR v_status NOT IN ('Served','Billed') THEN RETURN; END IF;
  SELECT COALESCE(SUM(amount), 0) INTO v_paid FROM payments WHERE order_id = p_order AND status = 'Success';
  IF v_paid < v_total THEN RETURN; END IF;
  v_prev := COALESCE(current_setting('dineflow.role', true), '');
  PERFORM set_config('dineflow.role', 'system', true);         -- closing the bill is a system action
  IF v_status = 'Served' THEN UPDATE orders SET status = 'Billed' WHERE order_id = p_order; END IF;
  UPDATE orders SET status = 'Paid' WHERE order_id = p_order;
  PERFORM set_config('dineflow.role', v_prev, true);
END $$;

CREATE FUNCTION fn_payments_after() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN PERFORM fn_try_close_order(NEW.order_id); RETURN NULL; END $$;
CREATE TRIGGER trg_payments_after AFTER INSERT OR UPDATE ON payments
  FOR EACH ROW WHEN (NEW.status = 'Success') EXECUTE FUNCTION fn_payments_after();

CREATE FUNCTION fn_orders_served_after() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN PERFORM fn_try_close_order(NEW.order_id); RETURN NULL; END $$;
CREATE TRIGGER trg_orders_served_after AFTER UPDATE ON orders
  FOR EACH ROW WHEN (NEW.status = 'Served' AND OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION fn_orders_served_after();

-- ---------------------------------------------------------------------
-- 2.7  RULE 4: a review needs a PAID order, written by the person who placed it.
--      (The composite FK in 01 already guarantees the dish is on that order.)
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_reviews_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_status order_status; v_owner INT;
BEGIN
  SELECT status, customer_id INTO v_status, v_owner FROM orders WHERE order_id = NEW.order_id;
  IF v_status IS DISTINCT FROM 'Paid' THEN RAISE EXCEPTION 'You can only review dishes from a paid order'; END IF;
  IF v_owner <> NEW.customer_id THEN RAISE EXCEPTION 'You can only review your own orders'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_reviews_guard BEFORE INSERT ON reviews
  FOR EACH ROW EXECUTE FUNCTION fn_reviews_guard();

-- ---------------------------------------------------------------------
-- 2.8  FEATURE B: reservations.
--      The EXCLUDE constraint (01) is the real guard; these add friendly rules and messages.
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_reservation_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_cap SMALLINT; v_active BOOLEAN;
BEGIN
  SELECT capacity, is_active INTO v_cap, v_active FROM restaurant_tables WHERE table_id = NEW.table_id;
  IF NOT FOUND THEN RETURN NEW; END IF;                        -- the foreign key reports it
  IF NOT v_active THEN RAISE EXCEPTION 'This table is out of service'; END IF;
  IF NEW.party_size > v_cap THEN RAISE EXCEPTION 'A party of % does not fit this table (seats %)', NEW.party_size, v_cap; END IF;
  IF TG_OP = 'INSERT' AND NEW.status = 'Booked' AND NEW.start_time < now() THEN
    RAISE EXCEPTION 'A reservation must start in the future';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_reservation_guard BEFORE INSERT OR UPDATE ON table_reservations
  FOR EACH ROW EXECUTE FUNCTION fn_reservation_guard();

CREATE FUNCTION fn_reserve_table(p_customer INT, p_table INT, p_party INT, p_start TIMESTAMPTZ, p_minutes INT DEFAULT 90)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_id INT;
BEGIN
  INSERT INTO table_reservations (customer_id, table_id, party_size, start_time, end_time)
  VALUES (p_customer, p_table, p_party, p_start, p_start + make_interval(mins => p_minutes))
  RETURNING reservation_id INTO v_id;
  RETURN v_id;
EXCEPTION
  WHEN exclusion_violation  THEN RAISE EXCEPTION 'That table is already booked for this time. Please choose another slot or table.';
  WHEN foreign_key_violation THEN RAISE EXCEPTION 'Unknown customer or table';
  WHEN check_violation      THEN RAISE EXCEPTION 'Invalid reservation time (a booking can last at most 3 hours)';
END $$;

CREATE FUNCTION fn_available_tables(p_start TIMESTAMPTZ, p_end TIMESTAMPTZ, p_party INT)
RETURNS TABLE (table_id INT, table_no TEXT, capacity INT, area TEXT) LANGUAGE sql STABLE AS $$
  SELECT t.table_id, t.table_no::text, t.capacity::int, t.area::text FROM restaurant_tables t
   WHERE t.is_active AND t.capacity >= p_party
     AND NOT EXISTS (SELECT 1 FROM table_reservations r
                      WHERE r.table_id = t.table_id AND r.status IN ('Booked','Seated')
                        AND tstzrange(r.start_time, r.end_time) && tstzrange(p_start, p_end))
   ORDER BY t.capacity, t.table_no
$$;

-- ---------------------------------------------------------------------
-- 2.9  FEATURE D: low stock.
--      The trigger keeps is_sold_out = (stock_qty = 0), also when an admin restocks.
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_menu_soldout() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.is_sold_out := (NEW.stock_qty = 0); RETURN NEW; END $$;
CREATE TRIGGER trg_menu_soldout BEFORE INSERT OR UPDATE OF stock_qty ON menu_items
  FOR EACH ROW EXECUTE FUNCTION fn_menu_soldout();

CREATE VIEW v_low_stock AS
SELECT m.item_id, m.name, c.name AS category, m.stock_qty, m.reorder_level, m.is_sold_out
  FROM menu_items m JOIN categories c USING (category_id)
 WHERE m.is_active AND m.stock_qty <= m.reorder_level
 ORDER BY m.stock_qty, m.name;

-- Implicit cursor: FOUND after UPDATE ... RETURNING
CREATE FUNCTION fn_restock(p_item INT, p_qty INT) RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_new INT;
BEGIN
  IF p_qty IS NULL OR p_qty <= 0 THEN RAISE EXCEPTION 'Restock quantity must be above 0'; END IF;
  UPDATE menu_items SET stock_qty = stock_qty + p_qty WHERE item_id = p_item RETURNING stock_qty INTO v_new;
  IF NOT FOUND THEN RAISE EXCEPTION 'Menu item % does not exist', p_item; END IF;
  RETURN v_new;
END $$;

-- Implicit cursor: FOR ... IN SELECT loop + GET DIAGNOSTICS ROW_COUNT.  Returns items topped up.
CREATE FUNCTION fn_restock_low_items(p_target INT DEFAULT 50) RETURNS INT LANGUAGE plpgsql AS $$
DECLARE r RECORD; v_n INT; v_count INT := 0;
BEGIN
  FOR r IN SELECT item_id FROM v_low_stock ORDER BY item_id LOOP
    UPDATE menu_items SET stock_qty = p_target WHERE item_id = r.item_id AND stock_qty < p_target;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_count := v_count + v_n;
  END LOOP;
  RETURN v_count;
END $$;

-- ---------------------------------------------------------------------
-- 2.10  FEATURE E: bill split.  A DEFERRED constraint trigger: you may insert the
--       shares one by one; the sum is checked when the transaction commits.
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_check_split_sum() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_order INT; v_n INT; v_sum NUMERIC; v_total NUMERIC;
BEGIN
  v_order := CASE WHEN TG_OP = 'DELETE' THEN OLD.order_id ELSE NEW.order_id END;
  SELECT COUNT(*), COALESCE(SUM(amount), 0) INTO v_n, v_sum FROM order_splits WHERE order_id = v_order;
  SELECT total_amt INTO v_total FROM orders WHERE order_id = v_order;
  IF v_n > 0 AND v_total IS NOT NULL AND v_sum <> v_total THEN
    RAISE EXCEPTION 'Split amounts (Rs %) must add up to the bill (Rs %)', v_sum, v_total;
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_split_sum AFTER INSERT OR UPDATE OR DELETE ON order_splits
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_split_sum();

-- ---------------------------------------------------------------------
-- 2.11  Views.  "Synonym-equivalent": PostgreSQL has no CREATE SYNONYM, so a
--       view (or the search_path) gives the same effect.
-- ---------------------------------------------------------------------
CREATE VIEW dishes AS SELECT * FROM menu_items;                  -- synonym for menu_items

-- FEATURE A: kitchen display
CREATE VIEW v_kitchen_queue AS
SELECT o.order_id, o.order_no, COALESCE(t.table_no, 'Takeaway') AS table_no, o.order_type, o.status,
       o.created_at,
       (EXTRACT(EPOCH FROM now() - o.created_at) / 60)::int AS minutes_waiting,
       CASE WHEN now() - o.created_at >= interval '25 minutes' THEN 'RED'
            WHEN now() - o.created_at >= interval '15 minutes' THEN 'AMBER' ELSE 'GREEN' END AS delay_flag,
       string_agg(oi.quantity || ' x ' || m.name || COALESCE(' (' || oi.note || ')', ''), ', ' ORDER BY oi.line_no) AS items
  FROM orders o
  JOIN order_items oi ON oi.order_id = o.order_id
  JOIN menu_items m   ON m.item_id = oi.item_id
  LEFT JOIN restaurant_tables t ON t.table_id = o.table_id
 WHERE o.status IN ('Placed','Preparing')
 GROUP BY o.order_id, o.order_no, t.table_no, o.order_type, o.status, o.created_at
 ORDER BY o.created_at;

-- FEATURE H: average rating per dish (dishes with no review show 0 reviews)
CREATE VIEW v_dish_ratings AS
SELECT m.item_id, m.name, COUNT(r.review_id) AS review_count,
       ROUND(AVG(r.rating), 2) AS avg_rating
  FROM menu_items m LEFT JOIN reviews r ON r.item_id = m.item_id
 GROUP BY m.item_id, m.name;

-- FEATURE F: reports.  Sales are counted on the day the order was closed (updated_at).
CREATE VIEW v_sales_last_7_days AS
SELECT d::date AS sale_date, COUNT(o.order_id) AS orders,
       COALESCE(SUM(o.subtotal), 0)     AS gross_sales,
       COALESCE(SUM(o.discount_amt), 0) AS discounts,
       COALESCE(SUM(o.tax_amt), 0)      AS gst,
       COALESCE(SUM(o.total_amt), 0)    AS net_sales
  FROM generate_series(current_date - 6, current_date, interval '1 day') d
  LEFT JOIN orders o ON o.status = 'Paid' AND o.updated_at::date = d::date
 GROUP BY d ORDER BY d;

CREATE VIEW v_top_dishes AS
SELECT m.name, SUM(oi.quantity) AS units_sold, SUM(oi.line_total) AS revenue
  FROM order_items oi JOIN orders o ON o.order_id = oi.order_id AND o.status = 'Paid'
  JOIN menu_items m ON m.item_id = oi.item_id
 GROUP BY m.name ORDER BY units_sold DESC, revenue DESC LIMIT 10;

CREATE VIEW v_peak_hours AS
SELECT EXTRACT(HOUR FROM created_at)::int AS hour_of_day, COUNT(*) AS orders, SUM(total_amt) AS net_sales
  FROM orders WHERE status = 'Paid' GROUP BY 1 ORDER BY orders DESC, hour_of_day;

CREATE VIEW v_restaurant_summary AS
SELECT (SELECT COUNT(*) FROM customers)                                         AS customers,
       (SELECT COUNT(*) FROM orders WHERE status = 'Paid')                      AS paid_orders,
       (SELECT COALESCE(SUM(total_amt), 0) FROM orders WHERE status = 'Paid')   AS revenue,
       (SELECT ROUND(COALESCE(AVG(total_amt), 0), 2) FROM orders WHERE status = 'Paid') AS avg_order_value,
       (SELECT COUNT(*) FROM orders WHERE status IN ('Placed','Preparing','Served','Billed')) AS open_orders,
       (SELECT COUNT(*) FROM v_low_stock)                                       AS low_stock_items,
       (SELECT ROUND(AVG(rating), 2) FROM reviews)                              AS avg_rating;

-- FEATURE G: order history and audit trail
CREATE VIEW v_order_history AS
SELECT o.order_id, o.order_no, o.customer_id, o.order_type, COALESCE(t.table_no, '-') AS table_no, o.status,
       o.subtotal, o.discount_amt, o.tax_amt, o.total_amt, o.created_at,
       string_agg(oi.quantity || ' x ' || m.name, ', ' ORDER BY oi.line_no) AS items
  FROM orders o
  LEFT JOIN restaurant_tables t ON t.table_id = o.table_id
  LEFT JOIN order_items oi ON oi.order_id = o.order_id
  LEFT JOIN menu_items m   ON m.item_id = oi.item_id
 GROUP BY o.order_id, t.table_no;

CREATE VIEW v_order_audit AS
SELECT record_id AS order_id, old_data ->> 'status' AS from_status, new_data ->> 'status' AS to_status,
       changed_by, changed_at
  FROM audit_log WHERE table_name = 'orders' AND action = 'STATUS' ORDER BY changed_at, audit_id;

-- ---------------------------------------------------------------------
-- 2.12  Dynamic SQL: one report function, four breakdowns.
--       The dimension is checked against a whitelist (never pasted from user input);
--       the dates travel as bind parameters ($1, $2), so there is no SQL injection.
--       Usage: SELECT * FROM fn_sales_by('category', current_date - 7, current_date);
-- ---------------------------------------------------------------------
CREATE FUNCTION fn_sales_by(p_dimension TEXT, p_from DATE, p_to DATE)
RETURNS TABLE (bucket TEXT, order_count BIGINT, sales_amount NUMERIC) LANGUAGE plpgsql AS $$
DECLARE v_key TEXT; v_measure TEXT := 'SUM(o.total_amt)'; v_from TEXT := 'orders o'; v_sql TEXT;
BEGIN
  CASE p_dimension
    WHEN 'day'  THEN v_key := 'to_char(o.updated_at, ''YYYY-MM-DD'')';
    WHEN 'hour' THEN v_key := 'lpad(EXTRACT(HOUR FROM o.created_at)::int::text, 2, ''0'') || '':00''';
    WHEN 'type' THEN v_key := 'o.order_type::text';
    WHEN 'category' THEN
      v_key := 'c.name::text'; v_measure := 'SUM(oi.line_total)';
      v_from := 'orders o JOIN order_items oi ON oi.order_id = o.order_id '
             || 'JOIN menu_items m ON m.item_id = oi.item_id JOIN categories c ON c.category_id = m.category_id';
    ELSE RAISE EXCEPTION 'Unknown report dimension "%"', p_dimension
         USING HINT = 'Use one of: day, hour, type, category';
  END CASE;
  v_sql := format('SELECT %s AS bucket, COUNT(DISTINCT o.order_id)::bigint, COALESCE(%s, 0) '
                  'FROM %s WHERE o.status = ''Paid'' AND o.updated_at::date BETWEEN $1 AND $2 '
                  'GROUP BY 1 ORDER BY 1', v_key, v_measure, v_from);
  RETURN QUERY EXECUTE v_sql USING p_from, p_to;
END $$;

-- ---------------------------------------------------------------------
-- 2.13  RULE 6: end-of-day settlement with EXPLICIT cursors.
--       Outer cursor c_orders: every Paid order closed on the day.
--       Inner parameterised cursor c_pay: that order's successful payments.
--       Result is upserted into daily_settlement (safe to re-run).
--       Usage: CALL sp_daily_settlement(current_date - 1);
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_daily_settlement(p_date DATE) LANGUAGE plpgsql AS $$
DECLARE
  c_orders CURSOR FOR
    SELECT order_id, subtotal, discount_amt, tax_amt, total_amt FROM orders
     WHERE status = 'Paid' AND updated_at::date = p_date ORDER BY order_id;
  c_pay CURSOR (p_order INT) FOR
    SELECT method, amount FROM payments WHERE order_id = p_order AND status = 'Success';
  r_o RECORD; r_p RECORD;
  v_cnt INT := 0;
  v_gross NUMERIC := 0; v_disc NUMERIC := 0; v_tax NUMERIC := 0; v_net NUMERIC := 0;
  v_upi NUMERIC := 0; v_card NUMERIC := 0; v_cash NUMERIC := 0;
BEGIN
  OPEN c_orders;
  LOOP
    FETCH c_orders INTO r_o;
    EXIT WHEN NOT FOUND;
    v_cnt := v_cnt + 1;
    v_gross := v_gross + r_o.subtotal; v_disc := v_disc + r_o.discount_amt;
    v_tax := v_tax + r_o.tax_amt;      v_net  := v_net  + r_o.total_amt;
    OPEN c_pay(r_o.order_id);
    LOOP
      FETCH c_pay INTO r_p;
      EXIT WHEN NOT FOUND;
      CASE r_p.method
        WHEN 'UPI'  THEN v_upi  := v_upi  + r_p.amount;
        WHEN 'Card' THEN v_card := v_card + r_p.amount;
        ELSE             v_cash := v_cash + r_p.amount;
      END CASE;
    END LOOP;
    CLOSE c_pay;
  END LOOP;
  CLOSE c_orders;

  INSERT INTO daily_settlement (settle_date, orders_count, gross_sales, discount_total, tax_total, net_sales,
                                upi_total, card_total, cash_total, generated_at)
  VALUES (p_date, v_cnt, v_gross, v_disc, v_tax, v_net, v_upi, v_card, v_cash, now())
  ON CONFLICT (settle_date) DO UPDATE SET
    orders_count = EXCLUDED.orders_count, gross_sales = EXCLUDED.gross_sales,
    discount_total = EXCLUDED.discount_total, tax_total = EXCLUDED.tax_total, net_sales = EXCLUDED.net_sales,
    upi_total = EXCLUDED.upi_total, card_total = EXCLUDED.card_total, cash_total = EXCLUDED.cash_total,
    generated_at = now();
EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'Settlement for % failed: %', p_date, SQLERRM;
END $$;

-- Self-check (capture for the report): objects created by this file
SELECT 'triggers' AS kind, COUNT(*) AS n FROM information_schema.triggers WHERE trigger_schema = 'dineflow'
UNION ALL SELECT 'functions/procedures', COUNT(*) FROM information_schema.routines WHERE routine_schema = 'dineflow'
UNION ALL SELECT 'views', COUNT(*) FROM information_schema.views WHERE table_schema = 'dineflow';
