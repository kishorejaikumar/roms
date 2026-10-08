-- =====================================================================
-- DineFlow | UNIT III : Normalization UNF -> 1NF -> 2NF -> 3NF -> BCNF -> 4NF -> 5NF
-- Self-contained: works in its own schema "dineflow_norm", so it can run before or after the seed.
-- Run after 01:  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/02_normalization.sql
-- Every step shows: the functional dependencies, the decomposition, and a lossless-join proof query
-- (the join of the pieces EXCEPT the original must be EMPTY, in both directions).
-- Relational algebra / calculus examples are in docs/relational_algebra.md.
-- =====================================================================
DROP SCHEMA IF EXISTS dineflow_norm CASCADE;
CREATE SCHEMA dineflow_norm;
SET search_path = dineflow_norm, public;

-- ---------------------------------------------------------------------
-- UNF: one paper bill.  "items" is a repeating group (several dishes in ONE cell).
--   RECEIPT( order_no, order_date, customer_id, customer_name, customer_phone, table_no, table_capacity,
--            { item_id, item_name, category_id, category_name, unit_price, qty } )
-- Functional dependencies of the business
--   F1  order_no                -> order_date, customer_id, table_no
--   F2  customer_id             -> customer_name, customer_phone
--   F3  table_no                -> table_capacity
--   F4  item_id                 -> item_name, category_id, unit_price
--   F5  category_id             -> category_name
--   F6  (order_no, item_id)     -> qty
-- ---------------------------------------------------------------------
CREATE TABLE receipt_unf (
  order_no INT PRIMARY KEY, order_date DATE, customer_id INT, customer_name TEXT, customer_phone TEXT,
  table_no TEXT, table_capacity INT, items JSONB                      -- the repeating group
);
INSERT INTO receipt_unf VALUES
 (1001,'2026-10-01',1,'Asha Rao','9810000001','T01',2,
  '[{"item_id":1,"item_name":"Paneer Tikka","category_id":1,"category_name":"Starters","unit_price":240,"qty":2},
    {"item_id":4,"item_name":"Butter Chicken","category_id":2,"category_name":"Mains","unit_price":340,"qty":1},
    {"item_id":11,"item_name":"Butter Naan","category_id":4,"category_name":"Breads","unit_price":55,"qty":4}]'),
 (1002,'2026-10-01',2,'Vikram Shah','9810000002','T04',4,
  '[{"item_id":8,"item_name":"Hyderabadi Chicken Biryani","category_id":3,"category_name":"Biryani & Rice","unit_price":320,"qty":2},
    {"item_id":11,"item_name":"Butter Naan","category_id":4,"category_name":"Breads","unit_price":55,"qty":2}]'),
 (1003,'2026-10-02',1,'Asha Rao','9810000001','T04',4,
  '[{"item_id":1,"item_name":"Paneer Tikka","category_id":1,"category_name":"Starters","unit_price":240,"qty":1},
    {"item_id":8,"item_name":"Hyderabadi Chicken Biryani","category_id":3,"category_name":"Biryani & Rice","unit_price":320,"qty":1}]');

-- ---------------------------------------------------------------------
-- 1NF: atomic values only; one row per bill line.  Key = (order_no, item_id).
-- Problem left: customer, table and dish facts repeat on every line (update anomaly:
-- change Asha's phone and you must change every row).
-- ---------------------------------------------------------------------
CREATE TABLE receipt_1nf AS
SELECT r.order_no, (x.item_id) AS item_id, r.order_date, r.customer_id, r.customer_name, r.customer_phone,
       r.table_no, r.table_capacity, x.item_name, x.category_id, x.category_name, x.unit_price, x.qty
  FROM receipt_unf r, jsonb_to_recordset(r.items)
       AS x(item_id INT, item_name TEXT, category_id INT, category_name TEXT, unit_price NUMERIC, qty INT);
ALTER TABLE receipt_1nf ADD PRIMARY KEY (order_no, item_id);

-- ---------------------------------------------------------------------
-- 2NF: remove PARTIAL dependencies (attribute depends on part of the key).
--   F1,F2,F3 depend on order_no only      -> ORDER_HDR
--   F4,F5    depend on item_id only       -> ITEM
--   F6       needs the whole key          -> ORDER_LINE
-- ---------------------------------------------------------------------
CREATE TABLE order_hdr_2nf AS
  SELECT DISTINCT order_no, order_date, customer_id, customer_name, customer_phone, table_no, table_capacity FROM receipt_1nf;
CREATE TABLE item_2nf AS
  SELECT DISTINCT item_id, item_name, category_id, category_name, unit_price FROM receipt_1nf;
CREATE TABLE order_line_2nf AS
  SELECT order_no, item_id, qty FROM receipt_1nf;
ALTER TABLE order_hdr_2nf  ADD PRIMARY KEY (order_no);
ALTER TABLE item_2nf       ADD PRIMARY KEY (item_id);
ALTER TABLE order_line_2nf ADD PRIMARY KEY (order_no, item_id);

-- ---------------------------------------------------------------------
-- 3NF: remove TRANSITIVE dependencies (non-key -> non-key).
--   order_no -> customer_id -> customer_name, customer_phone     => CUSTOMER
--   order_no -> table_no    -> table_capacity                    => DINING_TABLE
--   item_id  -> category_id -> category_name                     => CATEGORY
-- ---------------------------------------------------------------------
CREATE TABLE customer_3nf AS SELECT DISTINCT customer_id, customer_name, customer_phone FROM order_hdr_2nf;
CREATE TABLE dining_table_3nf AS SELECT DISTINCT table_no, table_capacity FROM order_hdr_2nf;
CREATE TABLE category_3nf AS SELECT DISTINCT category_id, category_name FROM item_2nf;
CREATE TABLE order_hdr_3nf AS SELECT order_no, order_date, customer_id, table_no FROM order_hdr_2nf;
CREATE TABLE item_3nf AS SELECT item_id, item_name, category_id, unit_price FROM item_2nf;
ALTER TABLE customer_3nf     ADD PRIMARY KEY (customer_id);
ALTER TABLE dining_table_3nf ADD PRIMARY KEY (table_no);
ALTER TABLE category_3nf     ADD PRIMARY KEY (category_id);
ALTER TABLE order_hdr_3nf    ADD PRIMARY KEY (order_no);
ALTER TABLE item_3nf         ADD PRIMARY KEY (item_id);
-- These tables are exactly DineFlow's customers, restaurant_tables, categories, orders, menu_items, order_items.

-- ---------------------------------------------------------------------
-- LOSSLESS-JOIN PROOF for the 3NF decomposition (both queries must return 0 rows)
-- ---------------------------------------------------------------------
CREATE VIEW rejoined_3nf AS
SELECT h.order_no, l.item_id, h.order_date, h.customer_id, c.customer_name, c.customer_phone, h.table_no, t.table_capacity,
       i.item_name, i.category_id, g.category_name, i.unit_price, l.qty
  FROM order_hdr_3nf h JOIN order_line_2nf l USING (order_no) JOIN customer_3nf c USING (customer_id)
  JOIN dining_table_3nf t USING (table_no) JOIN item_3nf i USING (item_id) JOIN category_3nf g USING (category_id);

SELECT 'lossless: original EXCEPT rejoined' AS check_name, COUNT(*) AS rows_found FROM (SELECT * FROM receipt_1nf EXCEPT SELECT * FROM rejoined_3nf) a
UNION ALL
SELECT 'lossless: rejoined EXCEPT original', COUNT(*) FROM (SELECT * FROM rejoined_3nf EXCEPT SELECT * FROM receipt_1nf) b;

-- Dependency check on the data: a true FD X -> Y has NO X value with 2 different Y values.
SELECT 'F2 customer_id -> name,phone violated by' AS fd_check, COUNT(*) AS violations FROM
  (SELECT customer_id FROM receipt_1nf GROUP BY customer_id HAVING COUNT(DISTINCT (customer_name, customer_phone)) > 1) v
UNION ALL SELECT 'F3 table_no -> capacity violated by', COUNT(*) FROM
  (SELECT table_no FROM receipt_1nf GROUP BY table_no HAVING COUNT(DISTINCT table_capacity) > 1) v
UNION ALL SELECT 'F4 item_id -> name,price violated by', COUNT(*) FROM
  (SELECT item_id FROM receipt_1nf GROUP BY item_id HAVING COUNT(DISTINCT (item_name, unit_price)) > 1) v;

-- ---------------------------------------------------------------------
-- BCNF: every determinant must be a candidate key.
-- All 3NF tables above satisfy it.  A table that is 3NF but NOT BCNF:
--   COUNTER_DUTY( staff, counter, supervisor )   -- pickup-counter rota
--   FDs:  (staff, counter) -> supervisor        and   supervisor -> counter  (a supervisor runs ONE counter)
--   Candidate keys: (staff, counter) and (staff, supervisor).
--   supervisor is not a superkey, so supervisor -> counter violates BCNF; it stays 3NF because
--   counter is a PRIME attribute.  Anomaly: counter 'Takeaway-1' cannot be recorded for a supervisor
--   until some staff member is assigned.
-- ---------------------------------------------------------------------
CREATE TABLE counter_duty (staff TEXT, counter TEXT, supervisor TEXT, PRIMARY KEY (staff, counter));
INSERT INTO counter_duty VALUES ('Ravi','Takeaway-1','Geeta'),('Sana','Takeaway-1','Geeta'),
                                ('Ravi','Bar','Imran'),('Tara','Bar','Imran');
CREATE TABLE supervisor_counter AS SELECT DISTINCT supervisor, counter FROM counter_duty;     -- supervisor -> counter
CREATE TABLE staff_supervisor   AS SELECT DISTINCT staff, supervisor FROM counter_duty;
ALTER TABLE supervisor_counter ADD PRIMARY KEY (supervisor);
ALTER TABLE staff_supervisor   ADD PRIMARY KEY (staff, supervisor);
SELECT 'BCNF lossless: original EXCEPT rejoined' AS check_name, COUNT(*) AS rows_found FROM
  (SELECT staff, counter, supervisor FROM counter_duty EXCEPT
   SELECT s.staff, c.counter, s.supervisor FROM staff_supervisor s JOIN supervisor_counter c USING (supervisor)) a
UNION ALL SELECT 'BCNF lossless: rejoined EXCEPT original', COUNT(*) FROM
  (SELECT s.staff, c.counter, s.supervisor FROM staff_supervisor s JOIN supervisor_counter c USING (supervisor)
   EXCEPT SELECT staff, counter, supervisor FROM counter_duty) b;

-- ---------------------------------------------------------------------
-- 4NF: no non-trivial MULTIVALUED dependency.
--   DISH_FACT( dish, allergen, meal_time ):  dish ->> allergen  and  dish ->> meal_time
--   A dish's allergens are independent of when it is served, so the table must hold every
--   combination: adding one meal time forces one new row per allergen (redundancy and update anomalies).
--   Decompose into DISH_ALLERGEN and DISH_MEAL_TIME.
-- ---------------------------------------------------------------------
CREATE TABLE dish_fact (dish TEXT, allergen TEXT, meal_time TEXT, PRIMARY KEY (dish, allergen, meal_time));
INSERT INTO dish_fact VALUES
 ('Paneer Tikka','Milk','Lunch'),('Paneer Tikka','Milk','Dinner'),
 ('Gulab Jamun','Milk','Lunch'),('Gulab Jamun','Milk','Dinner'),('Gulab Jamun','Gluten','Lunch'),('Gulab Jamun','Gluten','Dinner');
CREATE TABLE dish_allergen AS SELECT DISTINCT dish, allergen FROM dish_fact;
CREATE TABLE dish_meal_time AS SELECT DISTINCT dish, meal_time FROM dish_fact;
SELECT '4NF lossless: original EXCEPT rejoined' AS check_name, COUNT(*) AS rows_found FROM
  (SELECT * FROM dish_fact EXCEPT SELECT a.dish, a.allergen, m.meal_time FROM dish_allergen a JOIN dish_meal_time m USING (dish)) x
UNION ALL SELECT '4NF lossless: rejoined EXCEPT original', COUNT(*) FROM
  (SELECT a.dish, a.allergen, m.meal_time FROM dish_allergen a JOIN dish_meal_time m USING (dish) EXCEPT SELECT * FROM dish_fact) y;

-- ---------------------------------------------------------------------
-- 5NF (project-join normal form): a table that can only be rebuilt by joining THREE projections.
--   SUPPLY( supplier, ingredient, dish ) with the business rule
--     "if supplier S supplies ingredient I, dish D uses I, and S supplies for D, then S supplies I for D"
--   => join dependency  *( (supplier,ingredient), (ingredient,dish), (supplier,dish) ).
--   A 2-way split is LOSSY (creates false facts); the 3-way split is lossless.
-- ---------------------------------------------------------------------
CREATE TABLE supply (supplier TEXT, ingredient TEXT, dish TEXT, PRIMARY KEY (supplier, ingredient, dish));
INSERT INTO supply VALUES
 ('FreshFarm','Paneer','Paneer Tikka'),('FreshFarm','Paneer','Palak Paneer'),('FreshFarm','Spinach','Palak Paneer'),
 ('DairyCo','Paneer','Paneer Tikka');
-- DairyCo supplies Paneer, and Palak Paneer uses Paneer, but DairyCo does not supply Palak Paneer:
-- joining only (supplier,ingredient) with (ingredient,dish) would invent the false fact (DairyCo, Paneer, Palak Paneer).
CREATE TABLE sup_ing AS SELECT DISTINCT supplier, ingredient FROM supply;
CREATE TABLE ing_dish AS SELECT DISTINCT ingredient, dish FROM supply;
CREATE TABLE sup_dish AS SELECT DISTINCT supplier, dish FROM supply;
SELECT '5NF 2-way split (lossy): spurious rows' AS check_name, COUNT(*) AS rows_found FROM
  (SELECT s.supplier, s.ingredient, d.dish FROM sup_ing s JOIN ing_dish d USING (ingredient) EXCEPT SELECT * FROM supply) z
UNION ALL SELECT '5NF 3-way split: original EXCEPT rejoined', COUNT(*) FROM
  (SELECT * FROM supply EXCEPT
   SELECT s.supplier, s.ingredient, d.dish FROM sup_ing s JOIN ing_dish d USING (ingredient) JOIN sup_dish sd ON sd.supplier = s.supplier AND sd.dish = d.dish) a
UNION ALL SELECT '5NF 3-way split: rejoined EXCEPT original', COUNT(*) FROM
  (SELECT s.supplier, s.ingredient, d.dish FROM sup_ing s JOIN ing_dish d USING (ingredient) JOIN sup_dish sd ON sd.supplier = s.supplier AND sd.dish = d.dish
   EXCEPT SELECT * FROM supply) b;

-- ---------------------------------------------------------------------
-- JUSTIFIED DE-NORMALIZATION: a materialised view in the REAL schema.
--   The "top dishes / daily item sales" report joins orders, order_items and menu_items and
--   groups by day; it is read often and the data of a closed (Paid) day never changes.
--   So we store the aggregate once (redundancy on purpose) and refresh it after settlement.
--   Cost: stale until refreshed.  Gain: dashboard reads touch a few hundred rows, not every order line.
-- ---------------------------------------------------------------------
SET search_path = dineflow, public, extensions;
DROP MATERIALIZED VIEW IF EXISTS mv_item_sales_daily;
CREATE MATERIALIZED VIEW mv_item_sales_daily AS
SELECT o.updated_at::date AS sale_date, m.item_id, m.name AS item_name,
       SUM(oi.quantity) AS units_sold, SUM(oi.line_total) AS revenue
  FROM orders o JOIN order_items oi ON oi.order_id = o.order_id JOIN menu_items m ON m.item_id = oi.item_id
 WHERE o.status = 'Paid'
 GROUP BY o.updated_at::date, m.item_id, m.name;
CREATE UNIQUE INDEX uq_mv_item_sales ON mv_item_sales_daily (sale_date, item_id);   -- needed for REFRESH ... CONCURRENTLY
-- Refresh:  REFRESH MATERIALIZED VIEW CONCURRENTLY dineflow.mv_item_sales_daily;
DROP SCHEMA dineflow_norm CASCADE;   -- demo tables are no longer needed (comment this out to keep them for screenshots)
