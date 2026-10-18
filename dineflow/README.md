# DineFlow: Restaurant Order Management System
**24CS303 Database Management Systems (Lab Integrated) | PostgreSQL + Node.js/Express + HTML/CSS/JS**

Customers register, browse the menu, reserve tables, place dine-in or takeaway orders, apply coupons, pay by UPI/card/cash, split bills, track status and rate dishes. Kitchen staff run a live display; the admin manages orders, stock, prices and reports.
**The focus is the database.** The rules live in PostgreSQL (constraints, triggers, functions, procedures, one transaction per order); the website only exposes them.

Verified on PostgreSQL 16 and Node 22: all SQL files run in order without errors, `fn_run_tests()` passes **65 of 65**, `fn_run_security_tests()` passes **23 of 23**, `server/test/api.test.js` passes **63 of 63** and `server/test/auth.test.js` (session tokens) passes **10 of 10** (including two real concurrency races through HTTP).

**New in this version:** session limits (customer 60 min, staff 30 min, 15 idle minutes in the browser), admin can add categories and dishes and hide or show dishes from the website, and complete reservation rules (see below).

**Earlier additions:** (1) row-level security, (2) database roles with GRANT/REVOKE (the API runs every request as `df_anon`, `df_customer`, `df_kitchen` or `df_admin`), (3) backup and restore script, (4) live floor map for kitchen and admin.

## Folder map (syllabus coverage)
| File | Unit | What it shows |
|---|---|---|
| `db/01_schema_er.sql` | I, II | 17 tables, ENUMs, keys, CHECKs, sequence, exclusion constraint, partial unique indexes |
| `db/02_normalization.sql` | III | UNF -> 1NF -> 2NF -> 3NF -> BCNF -> 4NF -> 5NF, lossless-join queries, materialised view (justified de-normalisation) |
| `db/03_sql_programming.sql` | II | views, triggers, functions, procedure with explicit cursors, implicit cursors, exception handling, dynamic SQL, bcrypt in DB |
| `db/04_transactions.sql` + `04b_demo.sql` | IV | `fn_place_order` (one ACID tx, lock order, deadlock-safe), savepoints, isolation levels, two-session demos |
| `db/05_optimization.sql` + `05b_benchmark.sql` | V | 50,000-row loader, EXPLAIN vs EXPLAIN ANALYZE, composite and partial indexes, join-method comparison |
| `db/06_seed_data.sql` | all | realistic Indian menu, customers, coupons, 12 orders created through the real triggers |
| `db/07_tests.sql` | all | `fn_run_tests()`: 65 checks, everything rolled back |
| `db/08_security.sql` | security | roles, GRANT/REVOKE, row-level security, SECURITY DEFINER routines, `fn_run_security_tests()` (23 checks) |
| `db/backup_restore.sh` | recovery | `pg_dump`/`pg_restore` backup, restore, row-count verify and a disaster demo |
| `docs/relational_algebra.md`, `docs/diagrams.md` | III | algebra/calculus examples; Mermaid ER, architecture and status diagrams |
| `nosql/orders_mongo.js` | V | MongoDB document model and SQL-vs-NoSQL comparison |
| `server/` | | Express API: signed tokens, role checks, rate limit, parameterised SQL |
| `public/` | | single-page front end (customer, kitchen, admin) |
| `docs/demo_script.md`, `docs/DineFlow_Mini_Project_Report.docx` | | 5-minute demo and the full report (A4, page border, abstract, TOC, 8 sections) |
| `docs/figures/` | | PNG of the architecture, ER, status-flow, benchmark and floor-map figures |

## Run it locally
Requirements: Node 18+, PostgreSQL 15+ (needs the `pgcrypto` and `btree_gist` extensions, both ship with PostgreSQL).
```bash
createdb dineflow
DATABASE_URL=postgres://postgres:YOURPASS@localhost:5432/dineflow ./db/load_all.sh      # or run the files with psql -f in this order: 01, 02, 03, 04, 04b, 05, 05b, 06, 07, 08
cd server && cp .env.example .env      # edit DATABASE_URL, set TOKEN_SECRET, keep PGSSL=off locally, keep USE_DB_ROLES=on
npm install && npm start               # open http://localhost:3000
```
Demo logins: customer `asha.rao@example.in` / `Customer@123` (all six seeded customers use that password), admin `admin@dineflow.in` / `Admin@123`, kitchen `kitchen1@dineflow.in` / `Kitchen@123` (use the **Staff** button).
Tests: `psql ... -c "SET search_path=dineflow,public; SELECT * FROM fn_run_tests();"` and, with the server running on a freshly seeded DB, `cd server && BASE=http://localhost:3000 npm test`. Re-run `db/load_all.sh` to reset.

## Deploy as a public website (Supabase + Render, both have free tiers)
1. **Database (Supabase):** create a project, then Project Settings -> Database -> copy the connection string (use the *Session pooler* string if your network has no IPv6). Load the SQL from your laptop: `DATABASE_URL="<that string>" ./db/load_all.sh`. (Pasting files into the SQL Editor also works; run them in order.)
2. **Code (GitHub):** push this folder to a new GitHub repository (`.env` is git-ignored).
3. **Web service (Render):** New + -> Web Service (or Blueprint using `render.yaml`) -> pick the repo. Leave Root Directory blank (the server also serves the `public` folder). Build command `cd server && npm install`, start command `cd server && npm start`. Add environment variables `DATABASE_URL` (Supabase string), `TOKEN_SECRET` (long random text) and leave `PGSSL` unset.
4. Open the Render URL. `/api/health` should show `{"ok":true}`. Free services sleep when idle, so the first request can take ~30 seconds.
5. Run `08_security.sql` with the same user the API connects as (the Supabase `postgres` user). If you re-run `03` or `04` later, run `08` again. If you have not loaded 08 yet, set `USE_DB_ROLES=off` on Render, then switch it back to `on`.
6. Before the viva: change the seeded passwords (or delete the demo staff), or at least say they are demo accounts.

## Security checklist
- [x] Passwords hashed with bcrypt inside PostgreSQL (`pgcrypto`); the API never sees hashes
- [x] Customer id comes from the signed token, never from the request body
- [x] HMAC-SHA256 signed tokens with expiry; constant-time signature compare
- [x] Role checks on every route (customer / kitchen / admin) and again in database triggers
- [x] Least-privilege database roles + row-level security: even a bug in the API cannot show one customer another's orders; `password_hash` is unreadable by every API role
- [x] 100% parameterised queries; the one dynamic-SQL function uses a whitelist plus bind parameters
- [x] Login rate limit (5 failures / 15 min), 20 KB request limit, security headers + CSP, no raw database errors sent to the browser
- [ ] Before real use: HTTPS only (Render provides it), rotate `TOKEN_SECRET`, change demo passwords, add email verification and a password-reset flow

## Backup and restore
```bash
export DATABASE_URL=postgres://...dineflow            # live database
export RESTORE_URL=postgres://...dineflow_restore     # an EMPTY scratch database
./db/backup_restore.sh demo      # backup, restore, delete all orders on the copy, restore again, verify row counts
```
`backup`, `restore FILE` and `verify` can also be run on their own. Supabase also keeps daily backups; use its *direct* connection string for `pg_dump`.

## Troubleshooting: a page does not work (for example Floor map or Reserve a table)
1. Run the setup checker on the database your website uses: `psql "$DATABASE_URL" -f db/check_setup.sql` (or paste it into the Supabase SQL editor). Every row must be `t` (true). A `f` row tells you which file to run.
2. The most common causes are an older database: `03_sql_programming.sql` was not re-run after it gained `v_floor_map`, or `08_security.sql` was not run afterwards. Fix: run `03`, `04` (optional), then `08`, in that order, as the same user that `DATABASE_URL` uses.
3. If the page only says "Server error", set `DEBUG_ERRORS=on` in `server/.env` (or in the Render environment), restart, and reload the page: it then shows the real database error. Set it back to `off` afterwards.
4. Open the browser console (F12) and the server log; copy the first red error message.

## Session limits
- Customers stay signed in for **60 minutes**, staff (kitchen and admin) for **30 minutes**. The top bar shows the minutes left.
- Change them in `server/.env`: `SESSION_MINUTES_CUSTOMER=60` and `SESSION_MINUTES_STAFF=30`, then restart. The limit is absolute and enforced by the server (an expired token is refused with 401).
- The browser also signs a user out after **15 minutes without a click or key press** (`IDLE_MIN` in `public/app.js`) and warns one minute before.
- Wrong passwords: 5 failures per 15 minutes per email and address.

## Admin menu management
Admin, Stock & prices: **Add a new dish** (name, category, price, veg or non-veg, opening stock, description), **Add category**, and a **Hide / Show** button for every dish. Hidden dishes disappear from the customer menu and cannot be ordered, but keep their history (dishes with orders are hidden, never deleted).

## Reservation rules
- A booking must start **at least 10 minutes** from now and **at most 30 days** ahead; it lasts at most 3 hours.
- No two live bookings may overlap on one table (exclusion constraint), and one customer may not hold two bookings at the same time.
- A customer may hold **3 upcoming** bookings; cancelling one frees a place.
- When the guest orders on a table they booked (from 30 minutes before the start), the booking becomes **Seated** automatically and is linked to the order. Another guest cannot order on a table reserved within the next 90 minutes; the table list shows it greyed out as "reserved".
- Old bookings are cleaned up automatically: **No-show** 15 minutes after the end if no one came, **Completed** when the order is paid or cancelled.
