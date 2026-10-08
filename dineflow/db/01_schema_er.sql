-- =====================================================================
-- DineFlow | 24CS303 DBMS | STAGE 1 : UNIT I  (ER/EER -> relational schema)
-- PostgreSQL 14+ (tested on 16, Supabase compatible)
-- Run:  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/01_schema_er.sql
-- Everything lives in its own schema "dineflow", so re-running this file
-- is safe: it drops and rebuilds only DineFlow objects.
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS pgcrypto;     -- bcrypt hashing: crypt(), gen_salt()  (used in Stage 2)
CREATE EXTENSION IF NOT EXISTS btree_gist;   -- lets a GiST exclusion constraint mix "=" and "&&"

DROP SCHEMA IF EXISTS dineflow CASCADE;
CREATE SCHEMA dineflow;
-- "extensions" is where Supabase keeps pgcrypto; harmless on plain PostgreSQL
SET search_path = dineflow, public, extensions;

-- ---------------------------------------------------------------------
-- UNIT II (DDL): SEQUENCE for human-friendly order numbers (DF-1001 ...)
-- ---------------------------------------------------------------------
CREATE SEQUENCE order_no_seq START WITH 1001 INCREMENT BY 1;

-- ---------------------------------------------------------------------
-- UNIT I : Enumerated domains (a status can never hold a typo)
-- ---------------------------------------------------------------------
CREATE TYPE order_status       AS ENUM ('Placed','Preparing','Served','Billed','Paid','Cancelled');
CREATE TYPE order_type         AS ENUM ('Dine-in','Takeaway');
CREATE TYPE payment_method     AS ENUM ('UPI','Card','Cash');
CREATE TYPE payment_status     AS ENUM ('Pending','Success','Failed','Refunded');
CREATE TYPE reservation_status AS ENUM ('Booked','Seated','Completed','Cancelled','No-show');
CREATE TYPE discount_type      AS ENUM ('PERCENT','FLAT');
CREATE TYPE staff_role         AS ENUM ('kitchen','admin');

-- ---------------------------------------------------------------------
-- UNIT I : People.  Customers and staff are separate entities because
-- they have different attributes and different login roles.
-- ---------------------------------------------------------------------
CREATE TABLE customers (
  customer_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  full_name     VARCHAR(80)  NOT NULL CHECK (length(trim(full_name)) >= 2),
  email         VARCHAR(120) NOT NULL CHECK (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  phone         VARCHAR(15)  NOT NULL CHECK (phone ~ '^[0-9]{10}$'),
  password_hash TEXT         NOT NULL,                 -- bcrypt via pgcrypto, never plain text
  is_active     BOOLEAN      NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_customers_email ON customers (lower(email));   -- case-insensitive unique

CREATE TABLE staff (
  staff_id      INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  full_name     VARCHAR(80)  NOT NULL,
  email         VARCHAR(120) NOT NULL CHECK (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  password_hash TEXT         NOT NULL,
  role          staff_role   NOT NULL,                 -- 'kitchen' or 'admin'
  is_active     BOOLEAN      NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_staff_email ON staff (lower(email));

CREATE TABLE addresses (                                -- 1 customer : N addresses (takeaway/contact)
  address_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id INT NOT NULL REFERENCES customers(customer_id) ON DELETE CASCADE,
  label       VARCHAR(20) NOT NULL DEFAULT 'Home',
  line1       VARCHAR(120) NOT NULL,
  city        VARCHAR(60)  NOT NULL,
  pincode     CHAR(6)      NOT NULL CHECK (pincode ~ '^[0-9]{6}$'),
  is_default  BOOLEAN      NOT NULL DEFAULT FALSE
);
CREATE INDEX idx_addresses_customer ON addresses (customer_id);
CREATE UNIQUE INDEX uq_one_default_address ON addresses (customer_id) WHERE is_default;  -- partial unique

-- ---------------------------------------------------------------------
-- UNIT I : Floor and reservations
-- ---------------------------------------------------------------------
CREATE TABLE restaurant_tables (
  table_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  table_no  VARCHAR(5) NOT NULL UNIQUE,
  capacity  SMALLINT   NOT NULL CHECK (capacity BETWEEN 1 AND 20),
  area      VARCHAR(20) NOT NULL DEFAULT 'Indoor' CHECK (area IN ('Indoor','Outdoor','Family','Window')),
  is_active BOOLEAN    NOT NULL DEFAULT TRUE
);

CREATE TABLE table_reservations (
  reservation_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id    INT NOT NULL REFERENCES customers(customer_id)        ON DELETE RESTRICT,
  table_id       INT NOT NULL REFERENCES restaurant_tables(table_id)   ON DELETE RESTRICT,
  party_size     SMALLINT NOT NULL CHECK (party_size BETWEEN 1 AND 20),
  start_time     TIMESTAMPTZ NOT NULL,
  end_time       TIMESTAMPTZ NOT NULL,
  status         reservation_status NOT NULL DEFAULT 'Booked',
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT ck_resv_time     CHECK (end_time > start_time),
  CONSTRAINT ck_resv_max_len  CHECK (end_time - start_time <= interval '3 hours'),
  -- FEATURE B: the database itself refuses two live reservations that overlap on one table.
  CONSTRAINT ex_no_double_booking EXCLUDE USING gist (
    table_id WITH =,
    tstzrange(start_time, end_time) WITH &&
  ) WHERE (status IN ('Booked','Seated'))
);
CREATE INDEX idx_resv_customer ON table_reservations (customer_id);

-- ---------------------------------------------------------------------
-- UNIT I : Menu.  stock lives on the menu item (one row per dish).
-- ---------------------------------------------------------------------
CREATE TABLE categories (
  category_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name          VARCHAR(40) NOT NULL UNIQUE,
  display_order SMALLINT    NOT NULL DEFAULT 0
);

CREATE TABLE menu_items (
  item_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  category_id   INT NOT NULL REFERENCES categories(category_id) ON DELETE RESTRICT,
  name          VARCHAR(80) NOT NULL UNIQUE,
  description   VARCHAR(200),
  price         NUMERIC(8,2) NOT NULL CHECK (price > 0),
  is_veg        BOOLEAN NOT NULL DEFAULT TRUE,
  stock_qty     INT NOT NULL DEFAULT 0 CHECK (stock_qty >= 0),    -- blocks overselling
  reorder_level INT NOT NULL DEFAULT 10 CHECK (reorder_level >= 0),
  is_sold_out   BOOLEAN NOT NULL DEFAULT FALSE,                   -- set by trigger in Stage 2 (feature D)
  is_active     BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE INDEX idx_menu_category ON menu_items (category_id);

-- ---------------------------------------------------------------------
-- UNIT I : Coupons (feature C) -- every rule is a CHECK constraint
-- ---------------------------------------------------------------------
CREATE TABLE coupons (
  coupon_id          INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code               VARCHAR(20) NOT NULL UNIQUE CHECK (code = upper(code)),
  discount_type      discount_type NOT NULL,
  discount_value     NUMERIC(8,2) NOT NULL CHECK (discount_value > 0),
  min_order_amount   NUMERIC(8,2) NOT NULL DEFAULT 0 CHECK (min_order_amount >= 0),
  max_discount       NUMERIC(8,2) CHECK (max_discount IS NULL OR max_discount > 0),
  valid_from         TIMESTAMPTZ NOT NULL,
  valid_to           TIMESTAMPTZ NOT NULL,
  max_total_uses     INT NOT NULL CHECK (max_total_uses > 0),
  used_count         INT NOT NULL DEFAULT 0,
  per_customer_limit SMALLINT NOT NULL DEFAULT 1 CHECK (per_customer_limit > 0),
  is_active          BOOLEAN NOT NULL DEFAULT TRUE,
  CONSTRAINT ck_coupon_dates  CHECK (valid_to > valid_from),
  CONSTRAINT ck_coupon_pct    CHECK (discount_type <> 'PERCENT' OR discount_value <= 100),
  CONSTRAINT ck_coupon_used   CHECK (used_count >= 0 AND used_count <= max_total_uses)  -- usage counter can never pass the limit
);

-- ---------------------------------------------------------------------
-- UNIT I : Orders and lines.  M:N between orders and menu_items is
-- resolved by order_items (composite key).
-- ---------------------------------------------------------------------
CREATE TABLE orders (
  order_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  order_no       BIGINT NOT NULL UNIQUE DEFAULT nextval('order_no_seq'),   -- sequence
  customer_id    INT NOT NULL REFERENCES customers(customer_id)       ON DELETE RESTRICT,
  table_id       INT          REFERENCES restaurant_tables(table_id)  ON DELETE RESTRICT,
  reservation_id INT          REFERENCES table_reservations(reservation_id) ON DELETE SET NULL,
  coupon_id      INT          REFERENCES coupons(coupon_id)           ON DELETE RESTRICT,
  order_type     order_type   NOT NULL DEFAULT 'Dine-in',
  status         order_status NOT NULL DEFAULT 'Placed',
  subtotal       NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (subtotal   >= 0),
  discount_amt   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (discount_amt >= 0),
  tax_amt        NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (tax_amt    >= 0),   -- 5% GST (trigger, Stage 2)
  total_amt      NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (total_amt  >= 0),
  notes          VARCHAR(200),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- Dine-in needs a table; takeaway must not have one.
  CONSTRAINT ck_order_table CHECK ((order_type = 'Dine-in'  AND table_id IS NOT NULL)
                                OR (order_type = 'Takeaway' AND table_id IS NULL)),
  CONSTRAINT ck_order_discount CHECK (discount_amt <= subtotal),
  -- RULE 1 at row level: total = subtotal - discount + GST
  CONSTRAINT ck_order_total CHECK (total_amt = subtotal - discount_amt + tax_amt)
);
CREATE INDEX idx_orders_customer ON orders (customer_id);
CREATE INDEX idx_orders_status   ON orders (status);
-- FEATURE B (second half): a table can have only ONE live order at a time.
CREATE UNIQUE INDEX uq_one_live_order_per_table ON orders (table_id)
  WHERE table_id IS NOT NULL AND status NOT IN ('Paid','Cancelled');

CREATE TABLE order_items (
  order_id   INT NOT NULL REFERENCES orders(order_id)      ON DELETE CASCADE,
  line_no    SMALLINT NOT NULL,
  item_id    INT NOT NULL REFERENCES menu_items(item_id)   ON DELETE RESTRICT,
  quantity   SMALLINT NOT NULL CHECK (quantity BETWEEN 1 AND 20),
  unit_price NUMERIC(8,2) NOT NULL CHECK (unit_price > 0),         -- price snapshot at order time
  line_total NUMERIC(10,2) GENERATED ALWAYS AS (quantity * unit_price) STORED,
  note       VARCHAR(100),
  PRIMARY KEY (order_id, line_no),                                  -- composite key
  CONSTRAINT uq_order_item UNIQUE (order_id, item_id)               -- one line per dish; also the target of reviews' FK
);
CREATE INDEX idx_order_items_item ON order_items (item_id);

-- ---------------------------------------------------------------------
-- UNIT I : Payments, coupon usage, bill splits
-- ---------------------------------------------------------------------
CREATE TABLE payments (
  payment_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  order_id   INT NOT NULL REFERENCES orders(order_id) ON DELETE RESTRICT,
  method     payment_method NOT NULL,
  amount     NUMERIC(10,2) NOT NULL CHECK (amount > 0),
  status     payment_status NOT NULL DEFAULT 'Pending',
  upi_ref    VARCHAR(40),
  card_last4 CHAR(4),
  paid_at    TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT ck_pay_upi  CHECK (upi_ref    IS NULL OR method = 'UPI'),
  CONSTRAINT ck_pay_card CHECK (card_last4 IS NULL OR (method = 'Card' AND card_last4 ~ '^[0-9]{4}$')),
  CONSTRAINT ck_pay_time CHECK (status <> 'Success' OR paid_at IS NOT NULL)
);
CREATE INDEX idx_payments_order ON payments (order_id);

CREATE TABLE coupon_usage (                                          -- who used which coupon on which order
  usage_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  coupon_id      INT NOT NULL REFERENCES coupons(coupon_id)     ON DELETE RESTRICT,
  customer_id    INT NOT NULL REFERENCES customers(customer_id) ON DELETE RESTRICT,
  order_id       INT NOT NULL UNIQUE REFERENCES orders(order_id) ON DELETE CASCADE,  -- 1 coupon per order
  discount_given NUMERIC(10,2) NOT NULL CHECK (discount_given >= 0),
  used_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_coupon_usage_cc ON coupon_usage (coupon_id, customer_id);

-- FEATURE E: bill split.  Each row = one diner's share; sum must equal the bill (trigger, Stage 2).
CREATE TABLE order_splits (
  order_id   INT NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
  split_no   SMALLINT NOT NULL CHECK (split_no BETWEEN 1 AND 10),
  payer_name VARCHAR(60) NOT NULL,
  amount     NUMERIC(10,2) NOT NULL CHECK (amount > 0),
  payment_id INT REFERENCES payments(payment_id) ON DELETE SET NULL,  -- filled when that share is paid
  PRIMARY KEY (order_id, split_no)
);

-- ---------------------------------------------------------------------
-- UNIT I : Reviews per dish (feature H).  The composite FK means a review can
-- only point at a dish that really is on that order.  "Order must be Paid"
-- is enforced by a trigger in Stage 2.
-- ---------------------------------------------------------------------
CREATE TABLE reviews (
  review_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  order_id    INT NOT NULL,
  item_id     INT NOT NULL,
  customer_id INT NOT NULL REFERENCES customers(customer_id) ON DELETE CASCADE,
  rating      SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comment     VARCHAR(300),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_review_once UNIQUE (order_id, item_id),
  CONSTRAINT fk_review_line FOREIGN KEY (order_id, item_id) REFERENCES order_items (order_id, item_id) ON DELETE CASCADE
);
CREATE INDEX idx_reviews_item ON reviews (item_id);

-- ---------------------------------------------------------------------
-- UNIT I : status_flow = the legal state machine for orders (RULE 2).
-- Data, not code: changing the workflow is an INSERT/DELETE, not a redeploy.
-- allowed_roles says WHO may make each move ('system' = a trigger/procedure).
-- ---------------------------------------------------------------------
CREATE TABLE status_flow (
  from_status   order_status NOT NULL,
  to_status     order_status NOT NULL,
  allowed_roles TEXT[]       NOT NULL,
  PRIMARY KEY (from_status, to_status),
  CONSTRAINT ck_flow_roles CHECK (allowed_roles <@ ARRAY['customer','kitchen','admin','system']
                                  AND cardinality(allowed_roles) > 0),
  CONSTRAINT ck_flow_diff  CHECK (from_status <> to_status)
);
INSERT INTO status_flow VALUES
  ('Placed',    'Preparing', ARRAY['kitchen','admin']),
  ('Preparing', 'Served',    ARRAY['kitchen','admin']),
  ('Served',    'Billed',    ARRAY['admin','system']),
  ('Billed',    'Paid',      ARRAY['admin','system']),
  ('Placed',    'Cancelled', ARRAY['customer','admin']),     -- cancel only BEFORE Served
  ('Preparing', 'Cancelled', ARRAY['customer','admin']);

-- ---------------------------------------------------------------------
-- UNIT I : audit trail (feature G) and nightly settlement (RULE 6)
-- ---------------------------------------------------------------------
CREATE TABLE audit_log (
  audit_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  table_name VARCHAR(40) NOT NULL,
  record_id  INT         NOT NULL,
  action     VARCHAR(10) NOT NULL CHECK (action IN ('INSERT','UPDATE','DELETE','STATUS')),
  old_data   JSONB,
  new_data   JSONB,
  changed_by VARCHAR(60) NOT NULL DEFAULT 'system',
  changed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_record ON audit_log (table_name, record_id, changed_at);

CREATE TABLE daily_settlement (
  settle_date    DATE PRIMARY KEY,
  orders_count   INT           NOT NULL CHECK (orders_count >= 0),
  gross_sales    NUMERIC(12,2) NOT NULL,
  discount_total NUMERIC(12,2) NOT NULL,
  tax_total      NUMERIC(12,2) NOT NULL,
  net_sales      NUMERIC(12,2) NOT NULL,
  upi_total      NUMERIC(12,2) NOT NULL DEFAULT 0,
  card_total     NUMERIC(12,2) NOT NULL DEFAULT 0,
  cash_total     NUMERIC(12,2) NOT NULL DEFAULT 0,
  generated_at   TIMESTAMPTZ   NOT NULL DEFAULT now()
);

-- =====================================================================
-- Quick self-check: list every table created (capture this for Figure 6.1)
-- =====================================================================
SELECT table_name FROM information_schema.tables
 WHERE table_schema = 'dineflow' ORDER BY table_name;
