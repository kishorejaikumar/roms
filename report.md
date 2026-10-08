# DineFlow: A Database-Driven Restaurant Order Management System
**24CS303 Database Management Systems (Lab Integrated) | Mini Project Report**
Name / Register No: ____________  Department: ____________  Guide: ____________

## Abstract
Restaurants run on many people and much data at once: customers book and order, cooks work from a queue, cashiers collect money and managers watch stock and sales. Carelessly built systems double-book tables, oversell dishes, show bills that do not match the order, and let people see or change what they should not. DineFlow is a web-based Restaurant Order Management System that shows how database concepts solve these problems. It uses PostgreSQL 16 (hosted on Supabase), a Node.js/Express REST API and a plain HTML/CSS/JavaScript front end. The schema (17 tables) is mapped from an ER/EER model and normalised to 3NF/BCNF, with 4NF and 5NF demonstrated. Business rules are enforced inside the database by constraints, triggers, functions, procedures and one ACID transaction per order. A GiST exclusion constraint makes double-booking of a table impossible; row locks stop two customers buying the last dish; a status-flow table plus trigger controls the order life cycle and writes an audit trail; an explicit-cursor procedure produces the end-of-day settlement. Indexes were studied with EXPLAIN ANALYZE on 50,000 orders (a filter query fell from 3.490 ms to 0.226 ms and a "my orders" query from 3.281 ms to 0.040 ms). A MongoDB model is included for NoSQL comparison. Automated tests run 52 database checks and 41 API checks, all passing.
**Keywords:** DBMS, PostgreSQL, ER/EER, normalization, triggers, transactions, row locking, exclusion constraint, indexing, EXPLAIN ANALYZE, MongoDB.

## 1. Introduction
### 1.1 Background
Restaurants have moved from paper slips to digital ordering. A modern system must serve many users at once, keep prices and stock right, record payments and give reliable sales figures. All of this depends on the database underneath.
### 1.2 Problem statement
Manual or poorly designed systems suffer from: (1) redundant, inconsistent data; (2) two customers taking the same table; (3) overselling limited dishes; (4) no control over the order life cycle; (5) bills that do not equal items plus tax minus discount; (6) weak access control; (7) slow reports as history grows.
### 1.3 Proposed system
DineFlow lets customers register, browse the menu, reserve tables, place dine-in or takeaway orders, apply coupons, pay by UPI, card or cash, split bills, track status and rate dishes. Kitchen staff use a live display. The admin manages orders, stock, prices, reports and daily settlement. The database, not the application code, enforces the rules.
### 1.4 Scope
Included: customers, staff, tables, reservations, menu, stock, coupons, orders, payments, bill splits, reviews, audit log, settlement. Not included: a real payment gateway (a simulated one is used), e-mail/SMS, delivery tracking.

## 2. Objectives
1. Design an ER/EER model and map it to a relational schema with keys and constraints (Unit I).
2. Implement views, sequences, functions, procedures, cursors, triggers, exception handling and dynamic SQL (Unit II).
3. Show functional dependencies and normalise from UNF to BCNF/4NF/5NF with lossless-join proofs (Unit III).
4. Demonstrate ACID with concurrent orders, locking, savepoints, rollback on failed payment and isolation levels (Unit IV).
5. Optimise with indexes and EXPLAIN ANALYZE, build an end-of-day batch procedure, and compare with a MongoDB document model (Unit V).
6. Build a secure, role-based web application and deploy it publicly.

## 3. Tools and technologies
| Layer | Technology | Purpose |
|---|---|---|
| Database | PostgreSQL 16 (Supabase) | tables, triggers, PL/pgSQL, locking, JSONB, EXPLAIN |
| Extensions | pgcrypto, btree_gist | bcrypt hashing; exclusion constraint on time ranges |
| Back end | Node.js 18+, Express, pg, dotenv | REST API, token auth, transactions |
| Front end | HTML, CSS, vanilla JavaScript | customer, kitchen and admin screens |
| NoSQL | MongoDB shell script | document model for comparison |
| Hosting | Supabase + Render | public website |
| Testing | `fn_run_tests()`, `server/test/api.test.js` | 52 database + 41 API checks |

## 4. Architecture
Figures 4.1 (architecture), 4.2 (ER diagram) and 4.3 (order status flow) are in `docs/diagrams.md`.
The browser talks only to the API. The API verifies a signed token, sets the acting role and user id for the transaction (`set_config`), and calls database functions with bind parameters. Triggers read that role, so a rule holds even if a client bypasses the front end.
**EER notes.** `customers` and `staff` are separate entities. `order_items` resolves the many-to-many relationship between `orders` and `menu_items` with the composite key (order_id, line_no). `reviews` references `order_items(order_id, item_id)`, so a review can only point at a dish that is really on that order. `status_flow(from_status, to_status, allowed_roles)` stores the legal order life cycle as data.

## 5. Methodology (unit-wise)
### Unit I: ER/EER and relational mapping (`01_schema_er.sql`)
17 tables. One-to-many relationships became foreign keys (`ON DELETE RESTRICT` for business data so history is never lost, `CASCADE` for dependent rows). Unit prices are copied into each order line, so later price edits never change old bills. Constraints guard data at the source: NOT NULL, UNIQUE (case-insensitive e-mail), CHECK (price above 0, stock not below 0, rating 1 to 5, coupon dates and limits, `total = subtotal - discount + tax`), ENUM types for every status, and a sequence for order numbers. Two declarative concurrency guards: `EXCLUDE USING gist (table_id WITH =, tstzrange(start_time,end_time) WITH &&) WHERE status IN ('Booked','Seated')` forbids overlapping reservations, and a partial unique index allows one live order per table.
### Unit II: SQL programming (`03_sql_programming.sql`)
- **Rule 1, totals:** an AFTER trigger on `order_items` recomputes subtotal, coupon discount, 5% GST and total.
- **Rule 2, status flow:** a BEFORE UPDATE trigger looks the move up in `status_flow`, checks the actor's role (customers may cancel only their own orders, before Served), refuses `Paid` unless successful payments cover the bill, and an AFTER trigger writes `audit_log`.
- **Rule 4, reviews:** a trigger allows a review only for a Paid order of the same customer.
- **Rule 5, passwords:** `fn_register_customer` and `fn_login_*` hash and verify with `crypt()`/`gen_salt('bf')` inside the database.
- **Payments:** triggers stamp `paid_at`, reject payments above the amount due, and close the bill (Served, Billed, Paid) automatically when it is fully paid, including split bills.
- **Cancel:** a trigger returns stock in item order, releases the coupon and refunds payments.
- **Feature D:** a trigger keeps `is_sold_out = (stock_qty = 0)`; view `v_low_stock`.
- **Feature E:** a DEFERRABLE constraint trigger requires split shares to add up to the bill at commit.
- **Views:** `v_kitchen_queue`, `v_dish_ratings`, `v_sales_last_7_days`, `v_top_dishes`, `v_peak_hours`, `v_restaurant_summary`, `v_order_history`, `v_order_audit`, and `dishes` (a synonym-equivalent).
- **Cursors:** implicit (FOR loops, FOUND, `GET DIAGNOSTICS ROW_COUNT`) and explicit (OPEN/FETCH/CLOSE, one parameterised) in `sp_daily_settlement`, which stores gross, discount, GST, net and per-method totals in `daily_settlement`.
- **Exception handling:** `EXCEPTION WHEN unique_violation / check_violation / exclusion_violation / raise_exception`, `RAISE ... USING HINT`.
- **Dynamic SQL:** `fn_sales_by(dimension, from, to)` builds SQL with `format()`, whitelists the dimension and passes dates as `EXECUTE ... USING` bind parameters.
### Unit III: relational algebra and normalisation (`docs/relational_algebra.md`, `02_normalization.sql`)
Algebra and tuple-calculus examples use select, project, join, rename, union, intersection, difference, grouping and division. A flat receipt is normalised with every functional dependency listed (F1 order_no to date, customer, table; F2 customer_id to name, phone; F3 table_no to capacity; F4 item_id to name, category, price; F5 category_id to name; F6 (order_no, item_id) to qty): 1NF (one row per line), 2NF (order header, item, order line), 3NF (customer, table, category separated), BCNF (a counter-duty roster that is 3NF but not BCNF is decomposed), 4NF (dish allergens and meal times as independent multivalued facts) and 5NF (a supplier-ingredient-dish join dependency). A lossless-join check (`A EXCEPT B` and `B EXCEPT A` both return 0 rows) proves each decomposition; the 5NF script also shows that a two-way split is lossy. **Justified de-normalisation:** `mv_item_sales_daily` is a materialised view that stores daily item sales, because closed days never change and the dashboard reads it often; the cost is staleness until refreshed.
### Unit IV: transactions and concurrency (`04_transactions.sql`)
`fn_place_order` is one transaction: lock the table row (`FOR UPDATE`), reserve/seat, create the order, lock menu rows **in ascending item_id order**, check price and stock, insert lines, reduce stock, validate and lock the coupon, then record the payment. Lock order is always table, then menu rows, then coupon, so concurrent orders cannot wait on each other in a circle (deadlock-free). Any error, such as a declined card, rolls everything back (Atomicity); constraints and triggers give Consistency; row locks give Isolation; the write-ahead log gives Durability. The file also demonstrates SAVEPOINT / ROLLBACK TO SAVEPOINT, READ COMMITTED versus REPEATABLE READ, `NOWAIT` and `SKIP LOCKED`. The API retries on SQLSTATE 40001/40P01.
### Unit V: optimisation and NoSQL (`05_optimization.sql`, `nosql/orders_mongo.js`)
A rolled-back benchmark loads 50,000 orders and 150,000 order lines, then compares plans with `EXPLAIN` and `EXPLAIN ANALYZE`, single-column, composite and partial indexes, and the three join methods. The MongoDB script stores each order as one document with embedded items and payments, creates indexes, runs aggregation pipelines and ends with an SQL-versus-MongoDB comparison table.
### Back end and front end
Express serves the API and the static pages. Tokens are HMAC-SHA256 signed with expiry; every route checks the role; every query is parameterised; logins are rate limited; request size is limited; database errors are mapped to short messages. The front end is a single page with customer (menu, cart, coupon, payment, reservations, orders, split bill, rating), kitchen (live Kanban with delay colours) and admin (orders, audit, cash confirmation, stock, prices, reports, settlement) screens.

## 6. Results
Capture these screenshots and name them as shown.
| Figure | What to capture |
|---|---|
| 6.1 | Output of `01_schema_er.sql`: the list of 17 tables |
| 6.2 | `\df dineflow.*` or the "objects created" query at the end of `03_sql_programming.sql` |
| 6.3 | Customer menu page with ratings and a "Sold out" dish |
| 6.4 | Cart with coupon applied and the totals |
| 6.5 | My orders page with status steps; order details dialog |
| 6.6 | Reservation page: free tables list, then a blocked overlapping booking |
| 6.7 | Kitchen display with delay colours |
| 6.8 | Admin orders table with cash confirmation and audit dialog |
| 6.9 | Admin reports: 7-day bars, top dishes, settlement table |
| 6.10 | `SELECT * FROM fn_run_tests();` showing 52 passed |
| 6.11 | `npm test` showing 41 of 41 |
| 6.12 | Illegal status change error from the trigger |
| 6.13 | EXPLAIN ANALYZE before and after the index |
### 6.1 Automated tests
`fn_run_tests()` returns one row per check with its unit and a passed flag, and undoes all of its changes. **All 52 checks passed.** They cover constraints, password hashing and login, totals and GST, the status-flow trigger and role rules, review rules, low stock, reservations, dynamic SQL (including an injection attempt), the cursor settlement (net 1538.25 for the seeded day), `place_order` (merged lines, price snapshot, stock, atomicity, sold-out, stale price, failed card), four coupon rules, cancel side effects, prepaid and cash payment flows, split bills and deferred sum check. The API script adds **41 checks, all passed**, including role rejections, a tampered token, an injection attempt, and two real concurrent races: the last Rasmalai ordered by two customers (exactly one succeeds) and the same table ordered by two customers (exactly one succeeds).
### 6.2 Concurrency result
Two simultaneous HTTP requests for the final portion of a dish returned one 201 and one 409 ("sold out"); two simultaneous dine-in orders for table T02 returned one 201 and one 409. No double booking, no oversell, no deadlock.
### 6.3 Optimisation result (50,000 orders, PostgreSQL 16, one local machine)
| Query | Before | After |
|---|---|---|
| status = 'Preparing' and one customer | Seq Scan, 3.490 ms | Index Scan on `idx_orders_status`, 0.226 ms (about 15 times faster) |
| my 10 latest orders | Seq Scan + sort, 3.281 ms | Index Scan on `(customer_id, created_at DESC)`, 0.040 ms (about 80 times faster) |
| kitchen queue (live statuses) | status index, 0.278 ms | partial index, 0.349 ms (no gain at this size; the partial index is much smaller and matters as history grows) |
| Join of orders, lines, dishes (2-day window) | planner hash join 63.990 ms (cold), forced hash 33.095 ms, forced nested loop 22.137 ms, forced merge 19.498 ms | no single method always wins; the planner's cost model chose differently from the measured fastest here |
Timings depend on the machine and cache; the change in plan type is the stable result.
### 6.4 Discussion
Putting rules in the database means a bug in the web layer cannot break them; the API tests confirm the database messages reach the browser. The benchmark data is generated and evenly spread, so real gains for common statuses would be smaller. Testing caught a real routing bug (a customer-only guard accidentally blocking staff routes) before delivery.

## 7. Conclusion
DineFlow shows how the main ideas of a database course work together in one application: a normalised, constrained schema; triggers and functions that enforce business rules; a single locked transaction that keeps tables, stock and money correct; indexes verified with execution plans; and a document model for comparison. All checks passed and the system runs as a public website.
### 7.1 Limitations
Payments are simulated; there is no e-mail or SMS; the kitchen display polls every five seconds instead of using WebSockets; roles are customer, kitchen and admin only; benchmark data is synthetic.
### 7.2 Future scope
Real payment gateway in test mode, WebSocket updates, recipe-level inventory and supplier orders, table-wise live floor map, loyalty points, row-level security policies in PostgreSQL, and a mobile app.

## 8. References
1. A. Silberschatz, H. Korth, S. Sudarshan, *Database System Concepts*, McGraw-Hill.
2. R. Elmasri, S. Navathe, *Fundamentals of Database Systems*, Pearson.
3. PostgreSQL Documentation (PL/pgSQL, triggers, explicit locking, exclusion constraints, EXPLAIN, pgcrypto). https://www.postgresql.org/docs/
4. Express documentation. https://expressjs.com
5. node-postgres documentation. https://node-postgres.com
6. MongoDB Manual (aggregation, indexes). https://www.mongodb.com/docs/manual/
7. Supabase documentation. https://supabase.com/docs
8. Render documentation. https://render.com/docs
9. OWASP, SQL Injection Prevention Cheat Sheet. https://cheatsheetseries.owasp.org

## Appendix A: how to run
See `README.md` (local run, Supabase + Render deployment, troubleshooting) and `docs/demo_script.md` (5-minute demo).
