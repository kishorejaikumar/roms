# DineFlow: Restaurant Order Management System
**24CS303 Database Management Systems (Lab Integrated) | PostgreSQL + Node.js/Express + HTML/CSS/JS**

Customers register, browse the menu, reserve tables, place dine-in or takeaway orders, apply coupons, pay by UPI/card/cash, split bills, track status and rate dishes. Kitchen staff run a live display; the admin manages orders, stock, prices and reports.
**The focus is the database.** The rules live in PostgreSQL (constraints, triggers, functions, procedures, one transaction per order); the website only exposes them.

Verified on PostgreSQL 16 and Node 22: all seven SQL files run in order without errors, `fn_run_tests()` passes **52 of 52**, and `server/test/api.test.js` passes **41 of 41** (including two real concurrency races through HTTP).

## Folder map (syllabus coverage)
| File | Unit | What it shows |
|---|---|---|
| `db/01_schema_er.sql` | I, II | 17 tables, ENUMs, keys, CHECKs, sequence, exclusion constraint, partial unique indexes |
| `db/02_normalization.sql` | III | UNF -> 1NF -> 2NF -> 3NF -> BCNF -> 4NF -> 5NF, lossless-join queries, materialised view (justified de-normalisation) |
| `db/03_sql_programming.sql` | II | views, triggers, functions, procedure with explicit cursors, implicit cursors, exception handling, dynamic SQL, bcrypt in DB |
| `db/04_transactions.sql` | IV | `fn_place_order` (one ACID tx, lock order, deadlock-safe), savepoints, isolation levels, two-session demos |
| `db/05_optimization.sql` | V | 50,000-row loader, EXPLAIN vs EXPLAIN ANALYZE, composite and partial indexes, join-method comparison |
| `db/06_seed_data.sql` | all | realistic Indian menu, customers, coupons, 12 orders created through the real triggers |
| `db/07_tests.sql` | all | `fn_run_tests()`: 52 checks, everything rolled back |
| `docs/relational_algebra.md`, `docs/diagrams.md` | III | algebra/calculus examples; Mermaid ER, architecture and status diagrams |
| `nosql/orders_mongo.js` | V | MongoDB document model and SQL-vs-NoSQL comparison |
| `server/` | | Express API: signed tokens, role checks, rate limit, parameterised SQL |
| `public/` | | single-page front end (customer, kitchen, admin) |
| `docs/demo_script.md`, `docs/report.md` | | 5-minute demo and full report text |

## Run it locally
Requirements: Node 18+, PostgreSQL 14+ (needs the `pgcrypto` and `btree_gist` extensions, both ship with PostgreSQL).
```bash
createdb dineflow
DATABASE_URL=postgres://postgres:YOURPASS@localhost:5432/dineflow ./db/load_all.sh      # or run the 7 files with psql -f, in order
cd server && cp .env.example .env      # edit DATABASE_URL, set TOKEN_SECRET, keep PGSSL=off locally
npm install && npm start               # open http://localhost:3000
```
Demo logins: customer `asha.rao@example.in` / `Customer@123` (all six seeded customers use that password), admin `admin@dineflow.in` / `Admin@123`, kitchen `kitchen1@dineflow.in` / `Kitchen@123` (use the **Staff** button).
Tests: `psql ... -c "SET search_path=dineflow,public; SELECT * FROM fn_run_tests();"` and, with the server running on a freshly seeded DB, `cd server && BASE=http://localhost:3000 npm test`. Re-run `db/load_all.sh` to reset.

## Deploy as a public website (Supabase + Render, both have free tiers)
1. **Database (Supabase):** create a project, then Project Settings -> Database -> copy the connection string (use the *Session pooler* string if your network has no IPv6). Load the SQL from your laptop: `DATABASE_URL="<that string>" ./db/load_all.sh`. (Pasting files into the SQL Editor also works; run them in order.)
2. **Code (GitHub):** push this folder to a new GitHub repository (`.env` is git-ignored).
3. **Web service (Render):** New + -> Web Service (or Blueprint using `render.yaml`) -> pick the repo. Root directory `server`, build `npm install`, start `npm start`. Add environment variables `DATABASE_URL` (Supabase string), `TOKEN_SECRET` (long random text) and leave `PGSSL` unset.
4. Open the Render URL. `/api/health` should show `{"ok":true}`. Free services sleep when idle, so the first request can take ~30 seconds.
5. Before the viva: change the seeded passwords (or delete the demo staff), or at least say they are demo accounts.

## Security checklist
- [x] Passwords hashed with bcrypt inside PostgreSQL (`pgcrypto`); the API never sees hashes
- [x] Customer id comes from the signed token, never from the request body
- [x] HMAC-SHA256 signed tokens with expiry; constant-time signature compare
- [x] Role checks on every route (customer / kitchen / admin) and again in database triggers
- [x] 100% parameterised queries; the one dynamic-SQL function uses a whitelist plus bind parameters
- [x] Login rate limit (5 failures / 15 min), 20 KB request limit, security headers + CSP, no raw database errors sent to the browser
- [ ] Before real use: HTTPS only (Render provides it), rotate `TOKEN_SECRET`, change demo passwords, add email verification and a password-reset flow
