-- =====================================================================
-- DineFlow | Realistic seed data.  Run AFTER 01 and 03 (and 04 if you want place_order available).
-- The seed goes through the REAL triggers: totals are computed by the totals trigger,
-- statuses move along status_flow, payments close bills, the cancel trigger returns stock.
-- Demo logins:  admin@dineflow.in / Admin@123   kitchen1@dineflow.in / Kitchen@123
--               asha.rao@example.in / Customer@123 (all customers use Customer@123)
-- =====================================================================
SET search_path = dineflow, public, extensions;
SELECT set_config('dineflow.role', 'admin', false);       -- seed acts as admin for the whole session

-- ---------- Staff (bcrypt hashes made by the database) ----------------
INSERT INTO staff (full_name, email, password_hash, role) VALUES
 ('Anitha Raman',   'admin@dineflow.in',    crypt('Admin@123',   gen_salt('bf', 10)), 'admin'),
 ('Murugan Selvam', 'kitchen1@dineflow.in', crypt('Kitchen@123', gen_salt('bf', 10)), 'kitchen'),
 ('Lakshmi Pillai', 'kitchen2@dineflow.in', crypt('Kitchen@456', gen_salt('bf', 10)), 'kitchen');

-- ---------- Customers (through the registration function) --------------
SELECT fn_register_customer(n, e, p, 'Customer@123') FROM (VALUES
 ('Asha Rao',            'asha.rao@example.in',      '9810000001'),
 ('Vikram Shah',         'vikram.shah@example.in',   '9810000002'),
 ('Meera Iyer',          'meera.iyer@example.in',    '9810000003'),
 ('Karthik Subramanian', 'karthik.s@example.in',     '9810000004'),
 ('Divya Nair',          'divya.nair@example.in',    '9810000005'),
 ('Rohan Das',           'rohan.das@example.in',     '9810000006')) AS v(n, e, p);

INSERT INTO addresses (customer_id, label, line1, city, pincode, is_default) VALUES
 (1,'Home','12, Gandhi Street, Ambattur','Chennai','600053',TRUE),
 (2,'Home','45, MG Road, Indiranagar','Bengaluru','560038',TRUE),
 (4,'Office','7, Anna Salai','Chennai','600002',TRUE);

-- ---------- Floor ------------------------------------------------------
INSERT INTO restaurant_tables (table_no, capacity, area) VALUES
 ('T01',2,'Window'),('T02',2,'Indoor'),('T03',4,'Indoor'),('T04',4,'Indoor'),('T05',4,'Window'),
 ('T06',6,'Family'),('T07',6,'Family'),('T08',8,'Family'),('T09',4,'Outdoor'),('T10',2,'Outdoor');

-- ---------- Menu -------------------------------------------------------
INSERT INTO categories (name, display_order) VALUES
 ('Starters',1),('Mains',2),('Biryani & Rice',3),('Breads',4),('Beverages',5),('Desserts',6);

INSERT INTO menu_items (category_id, name, description, price, is_veg, stock_qty, reorder_level) VALUES
 (1,'Paneer Tikka','Tandoor-grilled cottage cheese, mint chutney',240,TRUE,120,20),
 (1,'Chicken 65','Spicy deep-fried chicken with curry leaves',260,FALSE,120,20),
 (1,'Crispy Corn','Fried corn kernels tossed with pepper',180,TRUE,50,15),
 (2,'Butter Chicken','Creamy tomato gravy, tandoori chicken',340,FALSE,120,20),
 (2,'Dal Makhani','Slow-cooked black lentils with butter',220,TRUE,120,20),
 (2,'Palak Paneer','Paneer cubes in spinach gravy',260,TRUE,100,20),
 (2,'Chettinad Chicken Curry','Pepper and fennel curry, Karaikudi style',330,FALSE,100,20),
 (3,'Hyderabadi Chicken Biryani','Dum biryani with raita',320,FALSE,150,25),
 (3,'Veg Dum Biryani','Seasonal vegetables, saffron rice',250,TRUE,120,25),
 (3,'Jeera Rice','Cumin-tempered basmati',120,TRUE,150,25),
 (4,'Butter Naan','Tandoor bread brushed with butter',55,TRUE,300,50),
 (4,'Garlic Naan','Naan with roasted garlic',65,TRUE,300,50),
 (4,'Tandoori Roti','Whole wheat tandoor roti',35,TRUE,300,50),
 (5,'Masala Chai','Ginger and cardamom tea',50,TRUE,200,30),
 (5,'Fresh Lime Soda','Sweet or salted',90,TRUE,200,30),
 (5,'Mango Lassi','Thick yoghurt and Alphonso mango',110,TRUE,150,30),
 (5,'Filter Coffee','Kumbakonam degree coffee',60,TRUE,200,30),
 (6,'Gulab Jamun','Two warm milk dumplings in syrup',95,TRUE,100,20),
 (6,'Rasmalai','Soft paneer discs in saffron milk',130,TRUE,100,20);

-- ---------- Coupons ----------------------------------------------------
INSERT INTO coupons (code, discount_type, discount_value, min_order_amount, max_discount, valid_from, valid_to, max_total_uses, per_customer_limit) VALUES
 ('WELCOME10','PERCENT',10,300, 100, now() - interval '30 days', now() + interval '180 days', 500, 1),
 ('FESTIVE15','PERCENT',15,1000,250, now() - interval '30 days', now() + interval '60 days',  200, 2),
 ('FLAT50',   'FLAT',   50,400, NULL,now() - interval '30 days', now() + interval '180 days', 1000,2),
 ('EXPIRED20','PERCENT',20,0,   NULL,now() - interval '60 days', now() - interval '10 days',  100, 1),
 ('LASTCALL', 'FLAT',   75,300, NULL,now() - interval '5 days',  now() + interval '30 days',  1,   1);

-- ---------- A past, completed reservation and two future ones ------------
INSERT INTO table_reservations (customer_id, table_id, party_size, start_time, end_time, status) VALUES
 (1, 1, 2, date_trunc('day', now()) - interval '6 days' + interval '13 hours',
           date_trunc('day', now()) - interval '6 days' + interval '14 hours 30 minutes', 'Completed');
SELECT fn_reserve_table(2, 4, 4, date_trunc('day', now()) + interval '1 day 20 hours', 90);
SELECT fn_reserve_table(3, 8, 6, date_trunc('day', now()) + interval '2 days 13 hours', 120);

-- ---------- 12 orders.  All start as Placed (distinct tables, so the one-live-order rule holds)
INSERT INTO orders (order_id, customer_id, table_id, reservation_id, coupon_id, order_type) OVERRIDING SYSTEM VALUE VALUES
 (1, 1, 1,    1,    NULL, 'Dine-in'),
 (2, 2, 4,    NULL, NULL, 'Dine-in'),
 (3, 3, NULL, NULL, NULL, 'Takeaway'),
 (4, 1, 2,    NULL, (SELECT coupon_id FROM coupons WHERE code='WELCOME10'), 'Dine-in'),
 (5, 4, 7,    NULL, (SELECT coupon_id FROM coupons WHERE code='FESTIVE15'), 'Dine-in'),
 (6, 5, 5,    NULL, NULL, 'Dine-in'),
 (7, 2, NULL, NULL, NULL, 'Takeaway'),
 (8, 6, 9,    NULL, NULL, 'Dine-in'),
 (9, 3, 6,    NULL, NULL, 'Dine-in'),
 (10,1, 3,    NULL, NULL, 'Dine-in'),
 (11,5, 10,   NULL, NULL, 'Dine-in'),
 (12,4, 8,    NULL, NULL, 'Dine-in');
SELECT setval(pg_get_serial_sequence('orders','order_id'), 12);

INSERT INTO order_items (order_id, line_no, item_id, quantity, unit_price, note)
SELECT v.oid, v.ln, m.item_id, v.q, m.price, v.note
  FROM (VALUES
   (1,1,'Paneer Tikka',2,'Extra mint chutney'),(1,2,'Butter Chicken',1,NULL),(1,3,'Butter Naan',4,NULL),(1,4,'Fresh Lime Soda',2,NULL),
   (2,1,'Hyderabadi Chicken Biryani',2,NULL),(2,2,'Chicken 65',1,NULL),(2,3,'Mango Lassi',2,NULL),(2,4,'Gulab Jamun',2,NULL),
   (3,1,'Veg Dum Biryani',1,NULL),(3,2,'Palak Paneer',1,NULL),(3,3,'Garlic Naan',2,NULL),(3,4,'Masala Chai',2,NULL),
   (4,1,'Dal Makhani',1,NULL),(4,2,'Jeera Rice',1,NULL),(4,3,'Tandoori Roti',3,NULL),(4,4,'Filter Coffee',2,NULL),
   (5,1,'Chettinad Chicken Curry',2,'Medium spicy'),(5,2,'Butter Naan',4,NULL),(5,3,'Veg Dum Biryani',1,NULL),(5,4,'Rasmalai',2,NULL),(5,5,'Mango Lassi',3,NULL),
   (6,1,'Chicken 65',2,NULL),(6,2,'Butter Chicken',2,NULL),(6,3,'Garlic Naan',4,NULL),(6,4,'Fresh Lime Soda',3,'No ice'),
   (7,1,'Hyderabadi Chicken Biryani',1,NULL),(7,2,'Masala Chai',1,NULL),
   (8,1,'Paneer Tikka',1,NULL),(8,2,'Palak Paneer',1,NULL),(8,3,'Jeera Rice',2,NULL),(8,4,'Butter Naan',3,NULL),(8,5,'Gulab Jamun',2,NULL),
   (9,1,'Dal Makhani',2,NULL),(9,2,'Tandoori Roti',2,NULL),
   (10,1,'Paneer Tikka',1,NULL),(10,2,'Butter Chicken',1,'Less spicy'),(10,3,'Garlic Naan',2,NULL),
   (11,1,'Hyderabadi Chicken Biryani',2,NULL),(11,2,'Fresh Lime Soda',2,NULL),
   (12,1,'Veg Dum Biryani',2,NULL),(12,2,'Dal Makhani',1,NULL),(12,3,'Butter Naan',3,NULL),(12,4,'Filter Coffee',2,NULL)
  ) AS v(oid, ln, nm, q, note) JOIN menu_items m ON m.name = v.nm;

-- Stock is reduced for every order (as place_order will do); order 9 is cancelled below and gets it back.
UPDATE menu_items m SET stock_qty = m.stock_qty - s.q
  FROM (SELECT item_id, SUM(quantity) AS q FROM order_items GROUP BY item_id) s WHERE s.item_id = m.item_id;

-- Coupon usage rows, then keep the coupon counters in step
INSERT INTO coupon_usage (coupon_id, customer_id, order_id, discount_given)
SELECT o.coupon_id, o.customer_id, o.order_id, o.discount_amt FROM orders o WHERE o.coupon_id IS NOT NULL;
UPDATE coupons c SET used_count = (SELECT COUNT(*) FROM coupon_usage u WHERE u.coupon_id = c.coupon_id);

-- Move orders along status_flow (the guard trigger checks every step)
UPDATE orders SET status = 'Preparing' WHERE order_id IN (1,2,3,4,5,6,7,8,11,12);
UPDATE orders SET status = 'Served'    WHERE order_id IN (1,2,3,4,5,6,7,8,12);
UPDATE orders SET status = 'Cancelled' WHERE order_id = 9;      -- cancel trigger returns the stock

-- Payments: the payment triggers close each bill (Served -> Billed -> Paid, table freed by status)
INSERT INTO payments (order_id, method, amount, status, upi_ref, card_last4)
SELECT o.order_id, v.m::payment_method, o.total_amt, 'Success', v.u, v.c
  FROM orders o JOIN (VALUES (1,'UPI','asha@okhdfc',NULL),(2,'Card',NULL,'4242'),(3,'UPI','meera@oksbi',NULL),
                             (4,'Cash',NULL,NULL),(6,'Card',NULL,'1881'),(7,'UPI','vikram@okicici',NULL),(8,'Cash',NULL,NULL))
       AS v(oid, m, u, c) ON v.oid = o.order_id;
-- Order 5 is a split bill: two diners, UPI + Cash
INSERT INTO payments (order_id, method, amount, status, upi_ref)
SELECT 5, 'UPI',  ROUND(total_amt / 2, 2), 'Success', 'karthik@okaxis' FROM orders WHERE order_id = 5;
INSERT INTO payments (order_id, method, amount, status)
SELECT 5, 'Cash', total_amt - ROUND(total_amt / 2, 2), 'Success' FROM orders WHERE order_id = 5;
INSERT INTO order_splits (order_id, split_no, payer_name, amount, payment_id)
SELECT order_id, (ROW_NUMBER() OVER (ORDER BY payment_id))::int, (ARRAY['Karthik','Divya'])[(ROW_NUMBER() OVER (ORDER BY payment_id))::int], amount, payment_id
  FROM payments WHERE order_id = 5;

-- Reviews (only possible for Paid orders; the trigger and composite FK check it)
INSERT INTO reviews (order_id, item_id, customer_id, rating, comment)
SELECT v.oid, m.item_id, o.customer_id, v.r, v.cm
  FROM (VALUES (1,'Paneer Tikka',5,'Perfectly charred'),(1,'Butter Chicken',4,'Rich and creamy'),
               (2,'Hyderabadi Chicken Biryani',5,'Best biryani in the area'),(2,'Gulab Jamun',4,NULL),
               (3,'Palak Paneer',4,NULL),(4,'Dal Makhani',5,'Slow cooked, lovely'),
               (5,'Chettinad Chicken Curry',5,'Proper pepper heat'),(5,'Rasmalai',3,'A little too sweet'),
               (6,'Chicken 65',4,NULL),(6,'Fresh Lime Soda',3,'Too much sugar'),
               (7,'Hyderabadi Chicken Biryani',5,NULL),(8,'Palak Paneer',4,NULL)) AS v(oid, nm, r, cm)
  JOIN menu_items m ON m.name = v.nm JOIN orders o ON o.order_id = v.oid;

-- Back-date history so the 7-day and peak-hour reports have a shape.  (dur = minutes from order to close)
UPDATE orders o SET created_at = date_trunc('day', now()) - make_interval(days => v.d) + make_interval(hours => v.h, mins => v.mi),
                    updated_at = date_trunc('day', now()) - make_interval(days => v.d) + make_interval(hours => v.h, mins => v.mi + v.dur)
  FROM (VALUES (1,6,13,10,55),(2,6,20,15,60),(3,5,19,40,35),(4,4,13,30,50),(5,3,20,45,75),
               (6,2,21,5,55),(7,1,13,20,30),(8,1,20,10,65),(9,1,19,0,5)) AS v(id, d, h, mi, dur)
 WHERE o.order_id = v.id;
UPDATE payments p SET paid_at = o.updated_at - interval '2 minutes', created_at = o.updated_at - interval '2 minutes'
  FROM orders o WHERE o.order_id = p.order_id AND o.status = 'Paid';
UPDATE orders SET created_at = now() - interval '6 minutes',  updated_at = now() - interval '6 minutes'  WHERE order_id = 10;
UPDATE orders SET created_at = now() - interval '18 minutes', updated_at = now() - interval '12 minutes' WHERE order_id = 11;
UPDATE orders SET created_at = now() - interval '40 minutes', updated_at = now() - interval '5 minutes'  WHERE order_id = 12;
UPDATE reviews SET created_at = now() - interval '1 day';

-- Final stock positions for the demo: a low item, a "last one" item and a sold-out item
UPDATE menu_items SET stock_qty = 1 WHERE name = 'Rasmalai';          -- demo: order the last one from two tabs
UPDATE menu_items SET stock_qty = 9 WHERE name = 'Gulab Jamun';       -- shows in v_low_stock
UPDATE menu_items SET stock_qty = 0 WHERE name = 'Crispy Corn';       -- trigger marks it sold out

SELECT set_config('dineflow.role', '', false);
DO $$ BEGIN   -- refresh the reporting materialised view if 02 has been run
  IF to_regclass('dineflow.mv_item_sales_daily') IS NOT NULL THEN REFRESH MATERIALIZED VIEW dineflow.mv_item_sales_daily; END IF;
END $$;
CALL sp_daily_settlement(current_date - 1);
CALL sp_daily_settlement(current_date - 2);

SELECT 'customers' AS what, COUNT(*) FROM customers UNION ALL SELECT 'menu_items', COUNT(*) FROM menu_items
UNION ALL SELECT 'orders', COUNT(*) FROM orders UNION ALL SELECT 'paid orders', COUNT(*) FROM orders WHERE status='Paid'
UNION ALL SELECT 'payments', COUNT(*) FROM payments UNION ALL SELECT 'audit rows', COUNT(*) FROM audit_log;
