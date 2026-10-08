// Sign-in, menu and table availability.
const router = require('express').Router();
const { query } = require('../db');
const { makeToken, requireRole, limiter } = require('../auth');
const { wrap, bad, str, int } = require('../util');
const anon = { role: 'anonymous' };

router.post('/auth/register', limiter, wrap(async (req, res) => {
  const { name, email, phone, password } = req.body || {};
  const [row] = await query(anon, 'SELECT fn_register_customer($1,$2,$3,$4) AS id', [str(name, 'name', 80), str(email, 'email'), String(phone || ''), String(password || '')]);
  res.status(201).json({ token: makeToken({ id: row.id, role: 'customer', name: name.trim() }), user: { id: row.id, role: 'customer', name: name.trim() } });
}));

router.post('/auth/login', limiter, wrap(async (req, res) => {
  const { email, password } = req.body || {};
  const [u] = await query(anon, 'SELECT * FROM fn_login_customer($1,$2)', [String(email || ''), String(password || '')]);
  if (!u) { req.loginFailed(); return res.status(401).json({ error: 'Wrong email or password' }); }
  req.loginOk();
  const user = { id: u.customer_id, role: 'customer', name: u.full_name };
  res.json({ token: makeToken(user), user });
}));

router.post('/auth/staff-login', limiter, wrap(async (req, res) => {
  const { email, password } = req.body || {};
  const [u] = await query(anon, 'SELECT * FROM fn_login_staff($1,$2)', [String(email || ''), String(password || '')]);
  if (!u) { req.loginFailed(); return res.status(401).json({ error: 'Wrong email or password' }); }
  req.loginOk();
  const user = { id: u.staff_id, role: u.role, name: u.full_name };
  res.json({ token: makeToken(user), user });
}));

router.get('/auth/me', requireRole('customer', 'kitchen', 'admin'), (req, res) => res.json({ user: req.user }));

router.get('/menu', wrap(async (_req, res) => {
  const rows = await query(anon, `SELECT m.item_id AS id, m.name, m.description, m.price, m.is_veg AS veg, m.is_sold_out AS "soldOut",
        m.stock_qty AS stock, c.name AS category, c.display_order AS "order", r.avg_rating AS rating, r.review_count AS reviews
      FROM menu_items m JOIN categories c USING (category_id) JOIN v_dish_ratings r ON r.item_id = m.item_id
     WHERE m.is_active ORDER BY c.display_order, m.name`);
  res.json({ items: rows });
}));

router.get('/tables/available', wrap(async (req, res) => {
  const start = new Date(String(req.query.start || ''));
  if (isNaN(start)) throw bad('Choose a valid date and time');
  const minutes = Math.min(Math.max(parseInt(req.query.minutes) || 90, 30), 180);
  const party = int(req.query.party || 2, 'party size');
  const rows = await query(anon, 'SELECT * FROM fn_available_tables($1, $2, $3)', [start.toISOString(), new Date(start.getTime() + minutes * 60000).toISOString(), party]);
  res.json({ tables: rows });
}));

router.get('/tables', wrap(async (_req, res) => {      // tables a customer can currently choose for dine-in (no live order, active)
  res.json({ tables: await query(anon, `SELECT t.table_id AS id, t.table_no AS no, t.capacity, t.area FROM restaurant_tables t
     WHERE t.is_active AND NOT EXISTS (SELECT 1 FROM orders o WHERE o.table_id = t.table_id AND o.status NOT IN ('Paid','Cancelled')) ORDER BY t.table_no`) });
}));

router.get('/reviews/dish/:id', wrap(async (req, res) => {
  res.json({ reviews: await query(anon, `SELECT r.rating, r.comment, r.created_at, split_part(c.full_name, ' ', 1) AS who
     FROM reviews r JOIN customers c USING (customer_id) WHERE r.item_id = $1 ORDER BY r.created_at DESC LIMIT 20`, [int(req.params.id, 'dish')]) });
}));
module.exports = router;
