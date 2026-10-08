# DineFlow: 5-minute demo script
Keep three windows ready: the website (customer), the website in a second browser profile (kitchen/admin), and a `psql` terminal with `SET search_path = dineflow, public;`.

## 1. Place an order and show the new rows (1 min)
Sign in as `asha.rao@example.in`, add 2 Paneer Tikka + 1 Butter Naan, choose table T01, apply coupon `FLAT50` (subtotal must be at least 400; Asha has not used it), pay by UPI `asha@okhdfc`, press Place order.
```sql
SELECT order_id, order_no, status, subtotal, discount_amt, tax_amt, total_amt FROM orders ORDER BY order_id DESC LIMIT 1;
SELECT * FROM order_items WHERE order_id = (SELECT max(order_id) FROM orders);
SELECT method, amount, status FROM payments WHERE order_id = (SELECT max(order_id) FROM orders);
SELECT item_id, name, stock_qty FROM menu_items WHERE name IN ('Paneer Tikka','Butter Naan');
```
Say: *one call, one transaction; the totals were computed by a trigger; stock dropped; the payment row exists.*

## 2. Illegal action rejected by a trigger (30 s)
```sql
UPDATE orders SET status = 'Paid' WHERE order_id = (SELECT max(order_id) FROM orders);
-- ERROR: Illegal status change: Placed -> Paid
SELECT * FROM status_flow;   -- the legal moves are DATA
SELECT * FROM v_order_audit WHERE order_id = (SELECT max(order_id) FROM orders);
```
Also in the UI: log in as kitchen, try the buttons; only legal next steps exist, and the API returns the trigger's message if forced.

## 3. Last item from two tabs (1 min)
Rasmalai has stock 1 (see `SELECT * FROM v_low_stock;`). Sign in as two different customers in two windows, add Rasmalai to both carts, press Place order in both at nearly the same moment.
Exactly one succeeds; the other shows "Rasmalai is sold out". Explain `SELECT ... FOR UPDATE` on the menu row. (Automated version: `npm test`, check 40.)

## 4. Reserve an already-booked table (45 s)
Reserve page -> pick tomorrow 20:00, 4 guests: T04 is already booked by the seed data. In psql:
```sql
SELECT fn_reserve_table(1, 4, 2, (SELECT start_time + interval '30 minutes' FROM table_reservations WHERE table_id = 4 AND status = 'Booked' LIMIT 1), 60);
-- ERROR: That table is already booked for this time...
```
Say: *this is an EXCLUDE USING gist constraint, not application code.*

## 5. EXPLAIN ANALYZE before and after an index (1 min)
```bash
psql "$DATABASE_URL" -f db/05_optimization.sql | less     # search for "== 5.1" and "== 5.2"
```
Point at: Seq Scan 3.490 ms -> Index Scan 0.226 ms (status filter); my-orders query 3.281 ms -> 0.040 ms with the composite index. Mention that timings differ on your machine.

## 6. Run the automated tests (30 s)
```sql
SELECT test_no, unit, passed, test_name FROM fn_run_tests();
SELECT count(*) FILTER (WHERE passed) AS passed, count(*) AS total FROM fn_run_tests();   -- 52 / 52
```
Close with: `SELECT * FROM fn_sales_by('category', current_date-7, current_date);` and `CALL sp_daily_settlement(current_date-1); SELECT * FROM daily_settlement;`.
