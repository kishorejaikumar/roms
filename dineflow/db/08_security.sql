-- =====================================================================
-- DineFlow | SECURITY: database roles, GRANT/REVOKE and Row-Level Security (RLS)
-- Run LAST (after 01-07), on PostgreSQL 15+, as the SAME user the API connects as:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/08_security.sql
-- Safe to re-run.  Re-run it after re-running 03 or 04 (CREATE OR REPLACE resets SECURITY DEFINER).
--
-- Design (least privilege, three layers):
--  1. Four NOLOGIN roles. The API connects as one user and runs  SET LOCAL ROLE df_<role>  per request.
--  2. GRANT/REVOKE: each role gets only the tables, COLUMNS and functions it needs
--     (nobody can read customers.password_hash; kitchen cannot see money columns).
--  3. RLS policies: a customer can only see rows that belong to them, even if the API had a bug.
--  Writes go through functions (fn_place_order ...), which are SECURITY DEFINER, so the
--  triggers they fire may touch stock, payments and audit rows without giving customers table rights.
-- =====================================================================
SET search_path = dineflow, public, extensions;
DO $$ BEGIN
  IF current_setting('server_version_num')::int < 150000 THEN RAISE EXCEPTION 'Run 08_security.sql on PostgreSQL 15 or newer'; END IF;
END $$;

-- ---------- 8.1 roles ---------------------------------------------------
DO $$ DECLARE r TEXT; BEGIN
  FOREACH r IN ARRAY ARRAY['df_anon','df_customer','df_kitchen','df_admin'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN EXECUTE format('CREATE ROLE %I NOLOGIN', r); END IF;
    EXECUTE format('GRANT %I TO CURRENT_USER', r);          -- the API user may SET ROLE to it
  END LOOP;
END $$;

-- ---------- 8.2 helpers that let the roles stay away from raw tables ----
CREATE OR REPLACE VIEW v_public_reviews AS               -- reviews without customer identity (first name only)
SELECT r.item_id, r.rating, r.comment, r.created_at, split_part(c.full_name, ' ', 1) AS who
  FROM reviews r JOIN customers c USING (customer_id);

CREATE OR REPLACE FUNCTION fn_free_tables() RETURNS TABLE (table_id INT, no TEXT, capacity INT, area TEXT)
LANGUAGE sql STABLE AS $$
  SELECT t.table_id, t.table_no::text, t.capacity::int, t.area::text FROM restaurant_tables t
   WHERE t.is_active AND NOT EXISTS (SELECT 1 FROM orders o WHERE o.table_id = t.table_id AND o.status NOT IN ('Paid','Cancelled'))
   ORDER BY t.table_no
$$;

CREATE OR REPLACE FUNCTION fn_refresh_reports() RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN REFRESH MATERIALIZED VIEW mv_item_sales_daily; END $$;

-- ---------- 8.3 every routine runs with its owner's rights (definer) -----
-- (test functions fn_run_* stay invoker because SET ROLE is not allowed inside definer functions)
DO $$ DECLARE r RECORD; BEGIN
  FOR r IN SELECT p.oid::regprocedure AS sig, p.prokind FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'dineflow' AND p.proname !~ '^fn_run_' LOOP
    EXECUTE format('ALTER %s %s SECURITY DEFINER SET search_path = dineflow, public, extensions',
                   CASE r.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END, r.sig);
  END LOOP;
END $$;

-- ---------- 8.4 GRANT / REVOKE: start from nothing ----------------------
REVOKE ALL ON SCHEMA dineflow FROM PUBLIC;
GRANT USAGE ON SCHEMA dineflow TO df_anon, df_customer, df_kitchen, df_admin;
REVOKE ALL ON ALL TABLES    IN SCHEMA dineflow FROM PUBLIC, df_anon, df_customer, df_kitchen, df_admin;
REVOKE ALL ON ALL ROUTINES  IN SCHEMA dineflow FROM PUBLIC, df_anon, df_customer, df_kitchen, df_admin;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA dineflow FROM PUBLIC, df_anon, df_customer, df_kitchen, df_admin;

CREATE OR REPLACE FUNCTION pg_temp.grant_exec(p_role TEXT, p_names TEXT[]) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'dineflow' AND p.proname = ANY (p_names) LOOP
    EXECUTE format('GRANT EXECUTE ON ROUTINE %s TO %I', r.sig, p_role);
  END LOOP;
END $$;

-- anonymous visitor: menu, sign-in, free-table search
GRANT SELECT ON menu_items, categories, v_dish_ratings, v_public_reviews TO df_anon;
SELECT pg_temp.grant_exec('df_anon', ARRAY['fn_ctx_role','fn_ctx_user','fn_register_customer','fn_login_customer','fn_login_staff','fn_available_tables','fn_free_tables']);

-- signed-in customer
GRANT SELECT ON menu_items, categories, restaurant_tables, orders, order_items, payments, order_splits,
                table_reservations, reviews, audit_log, v_dish_ratings, v_public_reviews, v_order_history, v_order_audit TO df_customer;
GRANT SELECT (customer_id, full_name, email, phone, is_active, created_at) ON customers TO df_customer;   -- no password_hash
GRANT INSERT ON reviews TO df_customer;
GRANT UPDATE (status) ON table_reservations TO df_customer;                                                 -- cancel own booking
SELECT pg_temp.grant_exec('df_customer', ARRAY['fn_ctx_role','fn_ctx_user','fn_place_order','fn_cancel_order','fn_pay_order','fn_split_bill',
  'fn_pay_split','fn_check_coupon','fn_coupon_discount','fn_reserve_table','fn_available_tables','fn_free_tables','fn_tables_for_customer','fn_expire_reservations']);

-- kitchen: sees order status and table, never money or customers
GRANT SELECT (order_id, order_no, table_id, order_type, status, created_at, updated_at, notes) ON orders TO df_kitchen;
GRANT UPDATE (status) ON orders TO df_kitchen;
GRANT SELECT ON v_kitchen_queue, v_floor_map TO df_kitchen;
SELECT pg_temp.grant_exec('df_kitchen', ARRAY['fn_ctx_role','fn_ctx_user','fn_expire_reservations']);

-- admin: everything, except password hashes
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA dineflow TO df_admin;
REVOKE ALL ON customers, staff FROM df_admin;
GRANT SELECT (customer_id, full_name, email, phone, is_active, created_at) ON customers TO df_admin;
GRANT SELECT (staff_id, full_name, email, role, is_active, created_at) ON staff TO df_admin;
GRANT EXECUTE ON ALL ROUTINES IN SCHEMA dineflow TO df_admin;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA dineflow TO df_admin;

-- ---------- 8.5 Row-Level Security --------------------------------------
DO $$ DECLARE r RECORD; BEGIN                       -- clean slate so the file can be re-run
  FOR r IN SELECT policyname, tablename FROM pg_policies WHERE schemaname = 'dineflow' LOOP
    EXECUTE format('DROP POLICY %I ON %I', r.policyname, r.tablename);
  END LOOP;
END $$;

ALTER TABLE orders             ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_items        ENABLE ROW LEVEL SECURITY;
ALTER TABLE payments           ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_splits       ENABLE ROW LEVEL SECURITY;
ALTER TABLE table_reservations ENABLE ROW LEVEL SECURITY;
ALTER TABLE reviews            ENABLE ROW LEVEL SECURITY;
ALTER TABLE customers          ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log          ENABLE ROW LEVEL SECURITY;

DO $$ DECLARE t TEXT; BEGIN
  FOREACH t IN ARRAY ARRAY['orders','order_items','payments','order_splits','table_reservations','reviews','customers','audit_log'] LOOP
    EXECUTE format('CREATE POLICY p_admin_all ON %I FOR ALL TO df_admin USING (true) WITH CHECK (true)', t);
  END LOOP;
END $$;

-- a customer sees ONLY rows that belong to them (fn_ctx_user() = id from the signed token)
CREATE POLICY p_cust_orders   ON orders             FOR SELECT TO df_customer USING (customer_id = fn_ctx_user());
CREATE POLICY p_cust_items    ON order_items        FOR SELECT TO df_customer USING (EXISTS (SELECT 1 FROM orders o WHERE o.order_id = order_items.order_id));
CREATE POLICY p_cust_pay      ON payments           FOR SELECT TO df_customer USING (EXISTS (SELECT 1 FROM orders o WHERE o.order_id = payments.order_id));
CREATE POLICY p_cust_splits   ON order_splits       FOR SELECT TO df_customer USING (EXISTS (SELECT 1 FROM orders o WHERE o.order_id = order_splits.order_id));
CREATE POLICY p_cust_resv_sel ON table_reservations FOR SELECT TO df_customer USING (customer_id = fn_ctx_user());
CREATE POLICY p_cust_resv_upd ON table_reservations FOR UPDATE TO df_customer USING (customer_id = fn_ctx_user()) WITH CHECK (customer_id = fn_ctx_user());
CREATE POLICY p_cust_rev_sel  ON reviews            FOR SELECT TO df_customer USING (customer_id = fn_ctx_user());
CREATE POLICY p_cust_rev_ins  ON reviews            FOR INSERT TO df_customer WITH CHECK (customer_id = fn_ctx_user());
CREATE POLICY p_cust_self     ON customers          FOR SELECT TO df_customer USING (customer_id = fn_ctx_user());
CREATE POLICY p_cust_audit    ON audit_log          FOR SELECT TO df_customer USING (table_name = 'orders' AND record_id IN (SELECT order_id FROM orders));
-- the kitchen reads live tickets and may update their status (the status trigger still decides which moves are legal)
CREATE POLICY p_kit_sel ON orders FOR SELECT TO df_kitchen USING (true);
CREATE POLICY p_kit_upd ON orders FOR UPDATE TO df_kitchen USING (status IN ('Placed','Preparing')) WITH CHECK (true);

-- views that return per-user rows must run with the CALLER's rights, so RLS applies to them
ALTER VIEW v_order_history SET (security_invoker = true);
ALTER VIEW v_order_audit   SET (security_invoker = true);

-- ---------- 8.6 security self-tests (all changes undone) ------------------
CREATE OR REPLACE FUNCTION fn_run_security_tests()
RETURNS TABLE (test_no INT, test_name TEXT, passed BOOLEAN) LANGUAGE plpgsql SET search_path = dineflow, public, extensions AS $$
DECLARE names TEXT[] := '{}'; oks BOOLEAN[] := '{}'; v_ok BOOLEAN; v_n BIGINT; v_n2 BIGINT; v_o INT;
BEGIN
  BEGIN
    PERFORM set_config('dineflow.user_id', '1', true);

    names := names || 'RLS: customer 1 sees only their own orders'::text;
    EXECUTE 'SET LOCAL ROLE df_customer'; SELECT COUNT(*) INTO v_n FROM orders; SELECT COUNT(*) INTO v_n2 FROM orders WHERE customer_id <> 1; EXECUTE 'RESET ROLE';
    oks := oks || (v_n = (SELECT COUNT(*) FROM orders WHERE customer_id = 1) AND v_n2 = 0 AND v_n < (SELECT COUNT(*) FROM orders));

    names := names || 'RLS: customer cannot see another customer''s payments, but sees their own'::text;
    EXECUTE 'SET LOCAL ROLE df_customer'; SELECT COUNT(*) INTO v_n FROM payments WHERE order_id = 2; SELECT COUNT(*) INTO v_n2 FROM payments WHERE order_id = 1; EXECUTE 'RESET ROLE';
    oks := oks || (v_n = 0 AND v_n2 > 0);

    names := names || 'RLS: the order history view only returns the caller''s orders'::text;
    EXECUTE 'SET LOCAL ROLE df_customer'; SELECT COUNT(*) INTO v_n FROM v_order_history WHERE customer_id <> 1; SELECT COUNT(*) INTO v_n2 FROM v_order_history; EXECUTE 'RESET ROLE';
    oks := oks || (v_n = 0 AND v_n2 > 0);

    names := names || 'RLS: the audit view only shows the caller''s own orders'::text;
    EXECUTE 'SET LOCAL ROLE df_customer'; SELECT COUNT(*) INTO v_n FROM v_order_audit WHERE order_id NOT IN (SELECT order_id FROM orders); SELECT COUNT(*) INTO v_n2 FROM v_order_audit; EXECUTE 'RESET ROLE';
    oks := oks || (v_n = 0 AND v_n2 > 0);

    names := names || 'RLS: customer sees only their own customers row'::text;
    EXECUTE 'SET LOCAL ROLE df_customer'; SELECT COUNT(*) INTO v_n FROM customers; EXECUTE 'RESET ROLE';
    oks := oks || (v_n = 1);

    names := names || 'GRANT: password_hash is unreadable for customer role'::text;
    v_ok := FALSE; BEGIN EXECUTE 'SET LOCAL ROLE df_customer'; PERFORM password_hash FROM customers; EXCEPTION WHEN insufficient_privilege THEN v_ok := TRUE; END; EXECUTE 'RESET ROLE';
    oks := oks || v_ok;

    names := names || 'GRANT: password_hash is unreadable even for the admin role'::text;
    v_ok := FALSE; BEGIN EXECUTE 'SET LOCAL ROLE df_admin'; PERFORM password_hash FROM staff; EXCEPTION WHEN insufficient_privilege THEN v_ok := TRUE; END; EXECUTE 'RESET ROLE';
    oks := oks || v_ok;

    names := names || 'GRANT: customer cannot change a menu price'::text;
    v_ok := FALSE; BEGIN EXECUTE 'SET LOCAL ROLE df_customer'; UPDATE menu_items SET price = 1; EXCEPTION WHEN insufficient_privilege THEN v_ok := TRUE; END; EXECUTE 'RESET ROLE';
    oks := oks || v_ok;

    names := names || 'GRANT: customer cannot read coupons or staff directly'::text;
    v_ok := FALSE; BEGIN EXECUTE 'SET LOCAL ROLE df_customer'; PERFORM 1 FROM coupons; EXCEPTION WHEN insufficient_privilege THEN v_ok := TRUE; END; EXECUTE 'RESET ROLE';
    v_n := 0; BEGIN EXECUTE 'SET LOCAL ROLE df_customer'; PERFORM 1 FROM staff; EXCEPTION WHEN insufficient_privilege THEN v_n := 1; END; EXECUTE 'RESET ROLE';
    oks := oks || (v_ok AND v_n = 1);

    names := names || 'RLS: customer cannot cancel someone else''s reservation (0 rows affected)'::text;
    EXECUTE 'SET LOCAL ROLE df_customer'; UPDATE table_reservations SET status = 'Cancelled' WHERE customer_id <> 1; GET DIAGNOSTICS v_n = ROW_COUNT; EXECUTE 'RESET ROLE';
    oks := oks || (v_n = 0);

    names := names || 'RLS: customer cannot write a review in another customer''s name'::text;
    v_ok := FALSE;
    BEGIN EXECUTE 'SET LOCAL ROLE df_customer'; INSERT INTO reviews (order_id, item_id, customer_id, rating) VALUES (2, (SELECT item_id FROM order_items WHERE order_id = 2 LIMIT 1), 2, 5);
    EXCEPTION WHEN insufficient_privilege THEN v_ok := TRUE; END; EXECUTE 'RESET ROLE';
    oks := oks || v_ok;

    names := names || 'Kitchen role: cannot read payments or the money columns of orders'::text;
    v_ok := FALSE; BEGIN EXECUTE 'SET LOCAL ROLE df_kitchen'; PERFORM 1 FROM payments; EXCEPTION WHEN insufficient_privilege THEN v_ok := TRUE; END; EXECUTE 'RESET ROLE';
    v_n := 0; BEGIN EXECUTE 'SET LOCAL ROLE df_kitchen'; PERFORM total_amt FROM orders; EXCEPTION WHEN insufficient_privilege THEN v_n := 1; END; EXECUTE 'RESET ROLE';
    oks := oks || (v_ok AND v_n = 1);

    names := names || 'Kitchen role: can start cooking a Placed order (policy + trigger allow it)'::text;
    PERFORM set_config('dineflow.role', 'kitchen', true);
    EXECUTE 'SET LOCAL ROLE df_kitchen'; UPDATE orders SET status = 'Preparing' WHERE order_id = 10; EXECUTE 'RESET ROLE';
    PERFORM set_config('dineflow.role', '', true);
    oks := oks || ((SELECT status FROM orders WHERE order_id = 10) = 'Preparing');

    names := names || 'Kitchen role: can read the kitchen queue and floor map'::text;
    EXECUTE 'SET LOCAL ROLE df_kitchen'; SELECT COUNT(*) INTO v_n FROM v_floor_map; SELECT COUNT(*) INTO v_n2 FROM v_kitchen_queue; EXECUTE 'RESET ROLE';
    oks := oks || (v_n = (SELECT COUNT(*) FROM restaurant_tables) AND v_n2 > 0);

    names := names || 'Anonymous role: reads the menu, cannot read orders'::text;
    EXECUTE 'SET LOCAL ROLE df_anon'; SELECT COUNT(*) INTO v_n FROM menu_items; EXECUTE 'RESET ROLE';
    v_ok := FALSE; BEGIN EXECUTE 'SET LOCAL ROLE df_anon'; PERFORM 1 FROM orders; EXCEPTION WHEN insufficient_privilege THEN v_ok := TRUE; END; EXECUTE 'RESET ROLE';
    oks := oks || (v_n = (SELECT COUNT(*) FROM menu_items) AND v_ok);

    names := names || 'Anonymous role: can still sign in through the login function'::text;
    EXECUTE 'SET LOCAL ROLE df_anon'; SELECT COUNT(*) INTO v_n FROM fn_login_customer('asha.rao@example.in', 'Customer@123'); EXECUTE 'RESET ROLE';
    oks := oks || (v_n = 1);

    names := names || 'Admin role: sees all orders'::text;
    EXECUTE 'SET LOCAL ROLE df_admin'; SELECT COUNT(*) INTO v_n FROM orders; EXECUTE 'RESET ROLE';
    oks := oks || (v_n = (SELECT COUNT(*) FROM orders));

    names := names || 'Definer functions: the customer role can place an order without any table rights'::text;
    PERFORM set_config('dineflow.role', 'customer', true);
    EXECUTE 'SET LOCAL ROLE df_customer';
    v_o := fn_place_order(1, 'Takeaway', NULL, jsonb_build_array(jsonb_build_object('itemId', (SELECT item_id FROM menu_items WHERE name = 'Masala Chai'), 'qty', 1)));
    SELECT COUNT(*) INTO v_n FROM orders WHERE order_id = v_o; EXECUTE 'RESET ROLE';
    PERFORM set_config('dineflow.role', '', true);
    oks := oks || (v_o IS NOT NULL AND v_n = 1);

    names := names || 'Every application routine is SECURITY DEFINER with a pinned search_path'::text;
    oks := oks || (SELECT COUNT(*) = 0 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname = 'dineflow' AND p.proname !~ '^fn_run_' AND (NOT p.prosecdef OR p.proconfig IS NULL));

    names := names || 'RLS is switched on for the 8 data tables'::text;
    oks := oks || ((SELECT COUNT(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                     WHERE n.nspname = 'dineflow' AND c.relrowsecurity) = 8);

    names := names || 'GRANT: customer role cannot run the add-dish function'::text;
    v_ok := FALSE; BEGIN EXECUTE 'SET LOCAL ROLE df_customer'; PERFORM fn_add_menu_item(1, 'Hacked Dish', 1, TRUE, 1); EXCEPTION WHEN insufficient_privilege THEN v_ok := TRUE; END; EXECUTE 'RESET ROLE';
    oks := oks || v_ok;

    names := names || 'GRANT: kitchen role cannot run the add-dish function'::text;
    v_ok := FALSE; BEGIN EXECUTE 'SET LOCAL ROLE df_kitchen'; PERFORM fn_add_menu_item(1, 'Hacked Dish', 1, TRUE, 1); EXCEPTION WHEN insufficient_privilege THEN v_ok := TRUE; END; EXECUTE 'RESET ROLE';
    oks := oks || v_ok;

    names := names || 'Admin role can add a dish through the function'::text;
    PERFORM set_config('dineflow.role', 'admin', true);
    EXECUTE 'SET LOCAL ROLE df_admin'; v_o := fn_add_menu_item(1, 'Security Test Dish', 99, TRUE, 5); EXECUTE 'RESET ROLE';
    PERFORM set_config('dineflow.role', '', true);
    oks := oks || (v_o IS NOT NULL AND EXISTS (SELECT 1 FROM menu_items WHERE name = 'Security Test Dish'));

    RAISE EXCEPTION 'rollback tests' USING ERRCODE = 'RB001';
  EXCEPTION WHEN SQLSTATE 'RB001' THEN NULL;
  END;
  RETURN QUERY SELECT i::int, names[i], oks[i] FROM generate_subscripts(names, 1) i;
END $$;

SELECT * FROM fn_run_security_tests();
