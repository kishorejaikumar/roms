-- =====================================================================
-- DineFlow | Automated database checks.  Run AFTER 01, 03, 04 and 06:
--   SELECT * FROM fn_run_tests();
-- Every change the tests make is undone (a final exception unwinds the sub-transaction),
-- so the data is exactly as before afterwards.
-- =====================================================================
SET search_path = dineflow, public, extensions;

CREATE OR REPLACE FUNCTION fn_run_tests()
RETURNS TABLE (test_no INT, unit TEXT, test_name TEXT, passed BOOLEAN) LANGUAGE plpgsql AS $$
DECLARE
  names TEXT[] := '{}'; units TEXT[] := '{}'; oks BOOLEAN[] := '{}';
  v_ok BOOLEAN; v_n NUMERIC; v_i INT; v_o INT; v_o2 INT; v_pid INT; v_stock INT; v_stock2 INT;
  v_cust INT; v_c2 INT; v_rasmalai INT; v_corn INT; v_paneer INT; v_chai INT; v_biryani INT; v_gulab INT;
  v_t1 INT; v_t2 INT; v_t4 INT; v_msg TEXT; v_used INT;
BEGIN
  BEGIN   -- sub-transaction: everything inside is undone at the end
    SELECT item_id INTO v_rasmalai FROM menu_items WHERE name = 'Rasmalai';
    SELECT item_id INTO v_corn     FROM menu_items WHERE name = 'Crispy Corn';
    SELECT item_id INTO v_paneer   FROM menu_items WHERE name = 'Paneer Tikka';
    SELECT item_id INTO v_chai     FROM menu_items WHERE name = 'Masala Chai';
    SELECT item_id INTO v_biryani  FROM menu_items WHERE name = 'Hyderabadi Chicken Biryani';
    SELECT item_id INTO v_gulab    FROM menu_items WHERE name = 'Gulab Jamun';
    SELECT table_id INTO v_t1 FROM restaurant_tables WHERE table_no = 'T01';
    SELECT table_id INTO v_t2 FROM restaurant_tables WHERE table_no = 'T02';
    SELECT table_id INTO v_t4 FROM restaurant_tables WHERE table_no = 'T04';
    v_cust := 1; v_c2 := 2;

    -- ===== Unit I : schema =====
    names := names || 'Seed data: 10 tables, 19 dishes, 6 customers, 12 orders'::text; units := units || 'I'::text;
    oks := oks || ((SELECT COUNT(*) FROM restaurant_tables) = 10 AND (SELECT COUNT(*) FROM menu_items) = 19
                   AND (SELECT COUNT(*) FROM customers) = 6 AND (SELECT COUNT(*) FROM orders) = 12);

    names := names || 'CHECK: dish price must be above 0'::text; units := units || 'I'::text;
    v_ok := FALSE; BEGIN UPDATE menu_items SET price = 0 WHERE item_id = v_paneer; EXCEPTION WHEN check_violation THEN v_ok := TRUE; END;
    oks := oks || v_ok;

    names := names || 'CHECK: stock can never go below 0'::text; units := units || 'I'::text;
    v_ok := FALSE; BEGIN UPDATE menu_items SET stock_qty = -1 WHERE item_id = v_paneer; EXCEPTION WHEN check_violation THEN v_ok := TRUE; END;
    oks := oks || v_ok;

    names := names || 'Dine-in order without a table rejected (ck_order_table)'::text; units := units || 'I'::text;
    v_ok := FALSE; BEGIN INSERT INTO orders (customer_id, order_type) VALUES (v_cust, 'Dine-in'); EXCEPTION WHEN check_violation THEN v_ok := TRUE; END;
    oks := oks || v_ok;

    -- ===== Unit II : programming =====
    names := names || 'Password stored as bcrypt hash, not plain text'::text; units := units || 'II'::text;
    oks := oks || ((SELECT password_hash FROM customers WHERE customer_id = 1) LIKE '$2%'
                   AND (SELECT password_hash FROM customers WHERE customer_id = 1) <> 'Customer@123');

    names := names || 'Login: correct password returns the customer'::text; units := units || 'II'::text;
    oks := oks || ((SELECT COUNT(*) FROM fn_login_customer('ASHA.RAO@example.in', 'Customer@123')) = 1);

    names := names || 'Login: wrong password returns nothing'::text; units := units || 'II'::text;
    oks := oks || ((SELECT COUNT(*) FROM fn_login_customer('asha.rao@example.in', 'wrong-pass')) = 0);

    names := names || 'Registration: duplicate email rejected with a clean message'::text; units := units || 'II'::text;
    v_ok := FALSE; BEGIN PERFORM fn_register_customer('Copy Cat', 'asha.rao@example.in', '9999999999', 'Password@1');
    EXCEPTION WHEN OTHERS THEN v_ok := (SQLERRM LIKE '%already registered%'); END;
    oks := oks || v_ok;

    names := names || 'Rule 1: order 4 total = 565 - 10% coupon + 5% GST = 533.93'::text; units := units || 'II'::text;
    oks := oks || ((SELECT total_amt FROM orders WHERE order_id = 4) = 533.93
                   AND (SELECT discount_amt FROM orders WHERE order_id = 4) = 56.50);

    names := names || 'Rule 1: every order satisfies total = subtotal - discount + tax'::text; units := units || 'II'::text;
    oks := oks || NOT EXISTS (SELECT 1 FROM orders WHERE total_amt <> subtotal - discount_amt + tax_amt);

    names := names || 'Rule 2: illegal move Placed -> Paid rejected by trigger'::text; units := units || 'II'::text;
    v_ok := FALSE; BEGIN UPDATE orders SET status = 'Paid' WHERE order_id = 10; EXCEPTION WHEN OTHERS THEN v_ok := (SQLERRM LIKE 'Illegal status change%'); END;
    oks := oks || v_ok;

    names := names || 'Rule 2: a customer cannot start cooking (role check)'::text; units := units || 'II'::text;
    PERFORM set_config('dineflow.role', 'customer', true); PERFORM set_config('dineflow.user_id', '1', true);
    v_ok := FALSE; BEGIN UPDATE orders SET status = 'Preparing' WHERE order_id = 10; EXCEPTION WHEN OTHERS THEN v_ok := (SQLERRM LIKE 'Role customer may not%'); END;
    oks := oks || v_ok;

    names := names || 'Rule 2: a different customer cannot cancel someone else''s order'::text; units := units || 'II'::text;
    PERFORM set_config('dineflow.user_id', '2', true);
    v_ok := FALSE; BEGIN UPDATE orders SET status = 'Cancelled' WHERE order_id = 10; EXCEPTION WHEN OTHERS THEN v_ok := (SQLERRM LIKE 'Only the customer who placed%'); END;
    oks := oks || v_ok;

    names := names || 'Rule 2: kitchen moves Placed -> Preparing and the audit log records it'::text; units := units || 'II'::text;
    PERFORM set_config('dineflow.role', 'kitchen', true); PERFORM set_config('dineflow.user_id', '2', true);
    UPDATE orders SET status = 'Preparing' WHERE order_id = 10;
    oks := oks || ((SELECT status FROM orders WHERE order_id = 10) = 'Preparing'
                   AND EXISTS (SELECT 1 FROM v_order_audit WHERE order_id = 10 AND from_status = 'Placed' AND to_status = 'Preparing' AND changed_by LIKE 'kitchen%'));

    names := names || 'Rule 2: kitchen cannot cancel (only customer/admin may)'::text; units := units || 'II'::text;
    v_ok := FALSE; BEGIN UPDATE orders SET status = 'Cancelled' WHERE order_id = 10; EXCEPTION WHEN OTHERS THEN v_ok := (SQLERRM LIKE 'Role kitchen may not%'); END;
    oks := oks || v_ok;
    PERFORM set_config('dineflow.role', '', true); PERFORM set_config('dineflow.user_id', '', true);

    names := names || 'Rule 4: review for an unpaid order rejected'::text; units := units || 'II'::text;
    v_ok := FALSE; BEGIN INSERT INTO reviews (order_id, item_id, customer_id, rating) VALUES (12, (SELECT item_id FROM order_items WHERE order_id = 12 LIMIT 1), 4, 5);
    EXCEPTION WHEN OTHERS THEN v_ok := (SQLERRM LIKE '%paid order%'); END;
    oks := oks || v_ok;

    names := names || 'Rule 4: review for a dish that is not on that order rejected (FK)'::text; units := units || 'II'::text;
    v_ok := FALSE; BEGIN INSERT INTO reviews (order_id, item_id, customer_id, rating) VALUES (7, v_corn, 2, 4); EXCEPTION WHEN foreign_key_violation THEN v_ok := TRUE; END;
    oks := oks || v_ok;

    names := names || 'Rule 4: review for a paid order accepted'::text; units := units || 'II'::text;
    INSERT INTO reviews (order_id, item_id, customer_id, rating, comment) VALUES (7, (SELECT item_id FROM menu_items WHERE name = 'Masala Chai'), 2, 4, 'Good chai');
    oks := oks || EXISTS (SELECT 1 FROM reviews WHERE order_id = 7 AND rating = 4);

    names := names || 'View: v_dish_ratings gives Paneer Tikka an average of 5.00'::text; units := units || 'II'::text;
    oks := oks || ((SELECT avg_rating FROM v_dish_ratings WHERE name = 'Paneer Tikka') = 5.00);

    names := names || 'Feature D: v_low_stock lists Rasmalai; Crispy Corn is auto-marked sold out'::text; units := units || 'II'::text;
    oks := oks || (EXISTS (SELECT 1 FROM v_low_stock WHERE name = 'Rasmalai')
                   AND (SELECT is_sold_out FROM menu_items WHERE item_id = v_corn));

    names := names || 'Feature D: restocking clears the sold-out flag'::text; units := units || 'II'::text;
    PERFORM fn_restock(v_corn, 30);
    oks := oks || (NOT (SELECT is_sold_out FROM menu_items WHERE item_id = v_corn));

    names := names || 'Feature B: fn_reserve_table rejects an overlapping booking'::text; units := units || 'II'::text;
    v_ok := FALSE; BEGIN
      PERFORM fn_reserve_table(3, v_t4, 2, (SELECT start_time + interval '30 minutes' FROM table_reservations WHERE table_id = v_t4 AND status = 'Booked' LIMIT 1), 60);
    EXCEPTION WHEN OTHERS THEN v_ok := (SQLERRM LIKE '%already booked%'); END;
    oks := oks || v_ok;

    names := names || 'Feature B: a non-overlapping slot on the same table is accepted'::text; units := units || 'II'::text;
    v_i := fn_reserve_table(3, v_t4, 2, (SELECT end_time + interval '30 minutes' FROM table_reservations WHERE table_id = v_t4 AND status = 'Booked' LIMIT 1), 60);
    oks := oks || (v_i IS NOT NULL);

    names := names || 'Feature B: party larger than the table rejected'::text; units := units || 'II'::text;
    v_ok := FALSE; BEGIN PERFORM fn_reserve_table(3, v_t1, 5, now() + interval '5 days', 60); EXCEPTION WHEN OTHERS THEN v_ok := (SQLERRM LIKE '%does not fit%'); END;
    oks := oks || v_ok;

    names := names || 'Dynamic SQL: fn_sales_by rejects an unknown (injected) dimension'::text; units := units || 'II'::text;
    v_ok := FALSE; BEGIN PERFORM fn_sales_by('day''; DROP TABLE orders; --', current_date - 7, current_date); EXCEPTION WHEN OTHERS THEN v_ok := (SQLERRM LIKE 'Unknown report dimension%'); END;
    oks := oks || v_ok;

    names := names || 'Dynamic SQL: fn_sales_by(''category'') returns 6 categories'::text; units := units || 'II'::text;
    oks := oks || ((SELECT COUNT(*) FROM fn_sales_by('category', current_date - 10, current_date)) = 6);

    names := names || 'Rule 6: cursor procedure sp_daily_settlement totals yesterday at 1538.25'::text; units := units || 'II'::text;
    DELETE FROM daily_settlement WHERE settle_date = current_date - 1;
    CALL sp_daily_settlement(current_date - 1);
    oks := oks || ((SELECT net_sales FROM daily_settlement WHERE settle_date = current_date - 1) = 1538.25
                   AND (SELECT orders_count FROM daily_settlement WHERE settle_date = current_date - 1) = 2
                   AND (SELECT upi_total + card_total + cash_total FROM daily_settlement WHERE settle_date = current_date - 1) = 1538.25);

    -- ===== Unit IV : place_order, ACID =====
    SELECT stock_qty INTO v_stock FROM menu_items WHERE item_id = v_paneer;
    v_o := fn_place_order(v_cust, 'Dine-in', v_t1, jsonb_build_array(
             jsonb_build_object('itemId', v_paneer, 'qty', 2, 'price', 240), jsonb_build_object('itemId', v_chai, 'qty', 1),
             jsonb_build_object('itemId', v_paneer, 'qty', 1)), NULL, NULL, 'Cash');

    names := names || 'place_order succeeds on a free table and the order is Placed'::text; units := units || 'IV'::text;
    oks := oks || (v_o IS NOT NULL AND (SELECT status FROM orders WHERE order_id = v_o) = 'Placed');

    names := names || 'place_order merges duplicate dishes (2 lines, Paneer qty 3) and snapshots price'::text; units := units || 'IV'::text;
    oks := oks || ((SELECT COUNT(*) FROM order_items WHERE order_id = v_o) = 2
                   AND (SELECT quantity FROM order_items WHERE order_id = v_o AND item_id = v_paneer) = 3
                   AND (SELECT unit_price FROM order_items WHERE order_id = v_o AND item_id = v_paneer) = 240);

    names := names || 'place_order reduced stock by exactly 3'::text; units := units || 'IV'::text;
    oks := oks || ((SELECT stock_qty FROM menu_items WHERE item_id = v_paneer) = v_stock - 3);

    names := names || 'Totals: 3 x 240 + 50 = 770, GST 38.50, total 808.50'::text; units := units || 'IV'::text;
    oks := oks || ((SELECT subtotal FROM orders WHERE order_id = v_o) = 770 AND (SELECT total_amt FROM orders WHERE order_id = v_o) = 808.50);

    names := names || 'Cash payment created as Pending for the full total'::text; units := units || 'IV'::text;
    oks := oks || EXISTS (SELECT 1 FROM payments WHERE order_id = v_o AND method = 'Cash' AND status = 'Pending' AND amount = 808.50);

    names := names || 'Same table twice: second order rejected (one live order per table)'::text; units := units || 'IV'::text;
    v_ok := FALSE; BEGIN PERFORM fn_place_order(v_c2, 'Dine-in', v_t1, '[{"itemId":1,"qty":1}]'); EXCEPTION WHEN OTHERS THEN v_ok := (SQLERRM LIKE '%already has an active order%'); END;
    oks := oks || v_ok;

    names := names || 'Direct INSERT on a busy table is blocked by the unique index'::text; units := units || 'IV'::text;
    v_ok := FALSE; BEGIN INSERT INTO orders (customer_id, table_id) VALUES (v_c2, v_t1); EXCEPTION WHEN unique_violation THEN v_ok := TRUE; END;
    oks := oks || v_ok;

    names := names || 'Atomicity: order above stock rejected, nothing left behind'::text; units := units || 'IV'::text;
    SELECT stock_qty INTO v_stock2 FROM menu_items WHERE item_id = v_gulab;
    v_ok := FALSE; BEGIN PERFORM fn_place_order(v_cust, 'Dine-in', v_t2, jsonb_build_array(jsonb_build_object('itemId', v_paneer, 'qty', 1), jsonb_build_object('itemId', v_gulab, 'qty', 20)));
    EXCEPTION WHEN OTHERS THEN v_ok := (SQLERRM LIKE 'Only % of Gulab Jamun left'); END;
    oks := oks || v_ok;

    names := names || 'Atomicity: failed order left Paneer stock, Gulab stock and table T02 untouched'::text; units := units || 'IV'::text;
    oks := oks || ((SELECT stock_qty FROM menu_items WHERE item_id = v_gulab) = v_stock2
                   AND (SELECT stock_qty FROM menu_items WHERE item_id = v_paneer) = (SELECT stock_qty FROM menu_items WHERE item_id = v_paneer)
                   AND NOT EXISTS (SELECT 1 FROM orders WHERE table_id = v_t2 AND status NOT IN ('Paid','Cancelled')));

    names := names || 'Sold-out dish (Crispy Corn at 0) cannot be ordered'::text; units := units || 'IV'::text;
    UPDATE menu_items SET stock_qty = 0 WHERE item_id = v_corn;
    v_ok := FALSE; BEGIN PERFORM fn_place_order(v_cust, 'Takeaway', NULL, jsonb_build_array(jsonb_build_object('itemId', v_corn, 'qty', 1))); EXCEPTION WHEN OTHERS THEN v_ok := (SQLERRM LIKE '%sold out'); END;
    oks := oks || v_ok;

    names := names || 'Stale client price rejected'::text; units := units || 'IV'::text;
    v_ok := FALSE; BEGIN PERFORM fn_place_order(v_cust, 'Takeaway', NULL, jsonb_build_array(jsonb_build_object('itemId', v_paneer, 'qty', 1, 'price', 1))); EXCEPTION WHEN OTHERS THEN v_ok := (SQLERRM LIKE 'The price of%'); END;
    oks := oks || v_ok;

    names := names || 'Failed payment (card 0000) rolls the whole order back'::text; units := units || 'IV'::text;
    SELECT COUNT(*) INTO v_i FROM orders; SELECT stock_qty INTO v_stock FROM menu_items WHERE item_id = v_paneer;
    v_ok := FALSE; BEGIN PERFORM fn_place_order(v_cust, 'Takeaway', NULL, jsonb_build_array(jsonb_build_object('itemId', v_paneer, 'qty', 2)), NULL, NULL, 'Card', NULL, '0000');
    EXCEPTION WHEN OTHERS THEN v_ok := (SQLERRM LIKE 'Card declined%'); END;
    oks := oks || (v_ok AND (SELECT COUNT(*) FROM orders) = v_i AND (SELECT stock_qty FROM menu_items WHERE item_id = v_paneer) = v_stock);

    -- coupons
    names := names || 'Coupon WELCOME10 applied: discount > 0, counter +1, usage row written'::text; units := units || 'IV'::text;
    SELECT used_count INTO v_used FROM coupons WHERE code = 'WELCOME10';
    v_o2 := fn_place_order(v_c2, 'Takeaway', NULL, jsonb_build_array(jsonb_build_object('itemId', v_biryani, 'qty', 2)), 'welcome10', NULL, 'UPI', 'vikram@okicici');
    oks := oks || ((SELECT discount_amt FROM orders WHERE order_id = v_o2) = 64.00
                   AND (SELECT used_count FROM coupons WHERE code = 'WELCOME10') = v_used + 1
                   AND EXISTS (SELECT 1 FROM coupon_usage WHERE order_id = v_o2 AND discount_given = 64.00));

    names := names || 'Coupon per-customer limit: second use by the same customer rejected'::text; units := units || 'IV'::text;
    v_ok := FALSE; BEGIN PERFORM fn_place_order(v_c2, 'Takeaway', NULL, jsonb_build_array(jsonb_build_object('itemId', v_biryani, 'qty', 2)), 'WELCOME10');
    EXCEPTION WHEN OTHERS THEN v_ok := (SQLERRM LIKE '%already used this coupon%'); END;
    oks := oks || v_ok;

    names := names || 'Coupon expiry: EXPIRED20 rejected'::text; units := units || 'IV'::text;
    v_ok := FALSE; BEGIN PERFORM fn_check_coupon('EXPIRED20', v_cust, 1000); EXCEPTION WHEN OTHERS THEN v_ok := (SQLERRM LIKE '%expired%'); END;
    oks := oks || v_ok;

    names := names || 'Coupon minimum order: FLAT50 on a Rs 50 order rejected'::text; units := units || 'IV'::text;
    v_ok := FALSE; BEGIN PERFORM fn_place_order(v_cust, 'Takeaway', NULL, jsonb_build_array(jsonb_build_object('itemId', v_chai, 'qty', 1)), 'FLAT50');
    EXCEPTION WHEN OTHERS THEN v_ok := (SQLERRM LIKE 'Minimum order%'); END;
    oks := oks || v_ok;

    names := names || 'Coupon total-use limit: LASTCALL works once, then is fully redeemed'::text; units := units || 'IV'::text;
    PERFORM fn_place_order(v_cust, 'Takeaway', NULL, jsonb_build_array(jsonb_build_object('itemId', v_biryani, 'qty', 1)), 'LASTCALL');
    v_ok := FALSE; BEGIN PERFORM fn_place_order(v_c2, 'Takeaway', NULL, jsonb_build_array(jsonb_build_object('itemId', v_biryani, 'qty', 1)), 'LASTCALL');
    EXCEPTION WHEN OTHERS THEN v_ok := (SQLERRM LIKE '%fully redeemed%'); END;
    oks := oks || v_ok;

    -- cancel returns stock and coupon
    names := names || 'Cancel: stock returned, coupon released, payment refunded'::text; units := units || 'IV'::text;
    SELECT stock_qty INTO v_stock FROM menu_items WHERE item_id = v_biryani; SELECT used_count INTO v_used FROM coupons WHERE code = 'WELCOME10';
    PERFORM fn_cancel_order(v_o2, 'customer', v_c2);
    oks := oks || ((SELECT stock_qty FROM menu_items WHERE item_id = v_biryani) = v_stock + 2
                   AND (SELECT used_count FROM coupons WHERE code = 'WELCOME10') = v_used - 1
                   AND NOT EXISTS (SELECT 1 FROM coupon_usage WHERE order_id = v_o2)
                   AND (SELECT status FROM payments WHERE order_id = v_o2) = 'Refunded');

    names := names || 'Cancel after Served is refused'::text; units := units || 'IV'::text;
    v_ok := FALSE; BEGIN PERFORM fn_cancel_order(12, 'admin', NULL); EXCEPTION WHEN OTHERS THEN v_ok := (SQLERRM LIKE '%Illegal status change%'); END;
    oks := oks || v_ok;

    -- payments and bill closing
    names := names || 'Prepaid UPI order auto-closes to Paid once the kitchen marks it Served'::text; units := units || 'IV'::text;
    v_o2 := fn_place_order(v_c2, 'Takeaway', NULL, jsonb_build_array(jsonb_build_object('itemId', v_chai, 'qty', 2)), NULL, NULL, 'UPI', 'vikram@okicici');
    PERFORM set_config('dineflow.role', 'kitchen', true);
    UPDATE orders SET status = 'Preparing' WHERE order_id = v_o2;
    UPDATE orders SET status = 'Served' WHERE order_id = v_o2;
    PERFORM set_config('dineflow.role', '', true);
    oks := oks || ((SELECT status FROM orders WHERE order_id = v_o2) = 'Paid'
                   AND (SELECT COUNT(*) FROM v_order_audit WHERE order_id = v_o2) = 4);

    names := names || 'Cash order: Paid only after an admin confirms the pending payment'::text; units := units || 'IV'::text;
    PERFORM set_config('dineflow.role', 'kitchen', true);
    UPDATE orders SET status = 'Preparing' WHERE order_id = v_o;
    UPDATE orders SET status = 'Served' WHERE order_id = v_o;
    PERFORM set_config('dineflow.role', '', true);
    v_ok := (SELECT status FROM orders WHERE order_id = v_o) = 'Served';
    PERFORM fn_confirm_payment((SELECT payment_id FROM payments WHERE order_id = v_o AND status = 'Pending'));
    oks := oks || (v_ok AND (SELECT status FROM orders WHERE order_id = v_o) = 'Paid');

    names := names || 'Payment above the amount due rejected'::text; units := units || 'IV'::text;
    v_ok := FALSE; BEGIN INSERT INTO payments (order_id, method, amount, status) VALUES (12, 'Cash', 99999, 'Pending'); EXCEPTION WHEN OTHERS THEN v_ok := (SQLERRM LIKE '%exceeds the amount still due%'); END;
    oks := oks || v_ok;

    names := names || 'Marking Paid without payments is rejected'::text; units := units || 'IV'::text;
    PERFORM set_config('dineflow.role', 'admin', true);
    UPDATE orders SET status = 'Billed' WHERE order_id = 12;
    v_ok := FALSE; BEGIN UPDATE orders SET status = 'Paid' WHERE order_id = 12; EXCEPTION WHEN OTHERS THEN v_ok := (SQLERRM LIKE 'Bill not fully paid%'); END;
    oks := oks || v_ok;
    PERFORM set_config('dineflow.role', '', true);

    names := names || 'Feature E: split in 3 shares sum to the bill; paying all shares closes the order'::text; units := units || 'IV'::text;
    PERFORM fn_split_bill(12, NULL, ARRAY['Karthik','Divya','Rahul']);
    SET CONSTRAINTS trg_split_sum IMMEDIATE;
    v_ok := (SELECT SUM(amount) FROM order_splits WHERE order_id = 12) = 1055.25;
    PERFORM fn_pay_split(12, 1, NULL, 'Cash'); PERFORM fn_pay_split(12, 2, NULL, 'UPI', 'divya@oksbi'); PERFORM fn_pay_split(12, 3, NULL, 'Card', NULL, '4242');
    PERFORM fn_confirm_payment(payment_id) FROM payments WHERE order_id = 12 AND status = 'Pending';
    oks := oks || (v_ok AND (SELECT status FROM orders WHERE order_id = 12) = 'Paid');

    names := names || 'Feature E: shares that do not add up to the bill are rejected'::text; units := units || 'IV'::text;
    v_ok := FALSE; BEGIN
      INSERT INTO order_splits (order_id, split_no, payer_name, amount) VALUES (10, 1, 'A', 100), (10, 2, 'B', 100);
      SET CONSTRAINTS trg_split_sum IMMEDIATE;
    EXCEPTION WHEN OTHERS THEN v_ok := (SQLERRM LIKE 'Split amounts%'); END;
    oks := oks || v_ok;

    RAISE EXCEPTION 'rollback tests' USING ERRCODE = 'RB001';
  EXCEPTION WHEN SQLSTATE 'RB001' THEN NULL;   -- unwinds all test data
  END;
  RETURN QUERY SELECT i::int, units[i], names[i], oks[i] FROM generate_subscripts(names, 1) i;
END $$;
