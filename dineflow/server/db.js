// Database access. EVERY request runs in one transaction that first tells PostgreSQL
// who is acting (role + user id), so the triggers in 03_sql_programming.sql can enforce the rules.
require('dotenv').config();
const { Pool, types } = require('pg');
types.setTypeParser(1700, parseFloat);   // NUMERIC -> JS number (money has 2 decimals, safe here)
types.setTypeParser(20, parseInt);       // BIGINT  -> number

const url = process.env.DATABASE_URL;
if (!url) { console.error('DATABASE_URL is missing. Copy .env.example to .env and fill it in.'); process.exit(1); }
const local = /localhost|127\.0\.0\.1/.test(url);
const pool = new Pool({
  connectionString: url, max: 10,
  ssl: process.env.PGSSL === 'off' || local ? false : { rejectUnauthorized: false }
});

// run(actor, fn): BEGIN; set search_path + actor; fn(client); COMMIT.  Retries on serialization/deadlock.
async function run(actor, fn) {
  for (let attempt = 1; ; attempt++) {
    const c = await pool.connect();
    try {
      await c.query('BEGIN');
      await c.query(`SELECT set_config('search_path', 'dineflow, public, extensions', true),
                            set_config('dineflow.role', $1, true), set_config('dineflow.user_id', $2, true)`,
                    [actor.role || 'anonymous', actor.id == null ? '' : String(actor.id)]);
      const result = await fn(c);
      await c.query('COMMIT');
      return result;
    } catch (e) {
      try { await c.query('ROLLBACK'); } catch (_) { /* connection already gone */ }
      if ((e.code === '40001' || e.code === '40P01') && attempt < 3) continue;   // retry safe failures
      throw e;
    } finally { c.release(); }
  }
}
const query = (actor, sql, params) => run(actor, async (c) => (await c.query(sql, params)).rows);
module.exports = { pool, run, query };
