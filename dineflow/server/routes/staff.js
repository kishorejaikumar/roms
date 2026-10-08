// Kitchen display (feature A) and the admin dashboard.
const router = require('express').Router();
const { run, query } = require('../db');
const { requireRole } = require('../auth');
const { wrap, bad, int } = require('../util');
const actor = (req) => ({ role: req.user.role, id: req.user.id });

// ---------- kitchen + admin ----------
router.get('/kitchen/queue', requireRole('kitchen', 'admin'), wrap(async (req, res) => {
  res.json({ queue: await query(actor(req), `SELECT order_id AS id, order_no AS "orderNo", table_no AS "tableNo", order_type AS type, status,
      minutes_waiting AS minutes, delay_flag AS flag, items FROM v_kitchen_queue`) });
}));
// The trigger decides whether this move is legal and whether THIS role may make it.
router.post('/kitchen/orders/:id/status', requireRole('kitchen', 'admin'), wrap(async (req, res) => {
  const to = String(req.body.status || '');
  if (!['Preparing', 'Served', 'Billed', 'Paid', 'Cancelled', 'Placed'].includes(to)) throw bad('Unknown status');
  const rows = await query(actor(req), 'UPDATE orders SET status = $1::order_status WHERE order_id = $2 RETURNING status', [to, int(req.params.id, 'order')]);
  if (!rows.length) throw bad('Order not found', 404);
  res.json({ status: rows[0].status });
}));

// ---------- admin only ----------
const admin = requireRole('admin');
router.get('/admin/orders', admin, wrap(async (req, res) => {
  const status = req.query.status ? String(req.query.status) : null;
  res.json({ orders: await query(actor(req), `SELECT h.order_id AS id, h.order_no AS "orderNo", c.full_name AS customer, h.order_type AS type, h.table_no AS "tableNo",
       h.status, h.total_amt AS total, h.created_at AS "createdAt", h.items,
       COALESCE((SELECT SUM(amount) FROM payments p WHERE p.order_id = h.order_id AND p.status = 'Success'), 0) AS paid,
       (SELECT json_agg(json_build_object('id', p.payment_id, 'method', p.method, 'amount', p.amount)) FROM payments p WHERE p.order_id = h.order_id AND p.status = 'Pending') AS "pendingPayments"
     FROM v_order_history h JOIN customers c ON c.customer_id = h.customer_id
    WHERE ($1::text IS NULL OR h.status::text = $1) ORDER BY h.created_at DESC LIMIT 100`, [status]) });
}));
router.post('/admin/payments/:id/confirm', admin, wrap(async (req, res) => {
  await query(actor(req), 'SELECT fn_confirm_payment($1)', [int(req.params.id, 'payment')]);
  res.json({ ok: true });
}));
router.get('/admin/audit/:orderId', admin, wrap(async (req, res) => {
  res.json({ trail: await query(actor(req), 'SELECT from_status AS "from", to_status AS "to", changed_by AS by, changed_at AS at FROM v_order_audit WHERE order_id = $1', [int(req.params.orderId, 'order')]) });
}));

// stock
router.get('/admin/low-stock', admin, wrap(async (req, res) => res.json({ items: await query(actor(req), 'SELECT item_id AS id, name, category, stock_qty AS stock, reorder_level AS "reorderLevel", is_sold_out AS "soldOut" FROM v_low_stock') })));
router.post('/admin/restock', admin, wrap(async (req, res) => {
  const [r] = await query(actor(req), 'SELECT fn_restock($1,$2) AS stock', [int(req.body.itemId, 'dish'), int(req.body.qty, 'quantity')]);
  res.json({ stock: r.stock });
}));
router.post('/admin/restock-low', admin, wrap(async (req, res) => {
  const [r] = await query(actor(req), 'SELECT fn_restock_low_items($1) AS n', [int(req.body.target || 50, 'target')]);
  res.json({ restocked: r.n });
}));
router.put('/admin/menu/:id', admin, wrap(async (req, res) => {
  const price = Number(req.body.price); if (!(price > 0) || price > 100000) throw bad('Price must be above 0');
  const rows = await query(actor(req), 'UPDATE menu_items SET price = $1 WHERE item_id = $2 RETURNING item_id', [price, int(req.params.id, 'dish')]);
  if (!rows.length) throw bad('Dish not found', 404);
  res.json({ ok: true });
}));

// reports (feature F)
router.get('/admin/reports/summary', admin, wrap(async (req, res) => {
  const [summary] = await query(actor(req), 'SELECT * FROM v_restaurant_summary');
  res.json({
    summary,
    week: await query(actor(req), 'SELECT sale_date AS date, orders, net_sales AS net, gst FROM v_sales_last_7_days'),
    top: await query(actor(req), 'SELECT name, units_sold AS units, revenue FROM v_top_dishes'),
    peak: await query(actor(req), 'SELECT hour_of_day AS hour, orders, net_sales AS net FROM v_peak_hours')
  });
}));
router.get('/admin/reports/by', admin, wrap(async (req, res) => {
  const to = req.query.to ? new Date(String(req.query.to)) : new Date(), from = req.query.from ? new Date(String(req.query.from)) : new Date(Date.now() - 30 * 864e5);
  if (isNaN(to) || isNaN(from)) throw bad('Invalid dates');
  res.json({ rows: await query(actor(req), 'SELECT bucket, order_count AS orders, sales_amount AS sales FROM fn_sales_by($1,$2,$3)', [String(req.query.dimension || ''), from.toISOString().slice(0, 10), to.toISOString().slice(0, 10)]) });
}));
router.get('/admin/reports/item-sales', admin, wrap(async (req, res) => {          // reads the materialised view (denormalised on purpose)
  res.json({ rows: await query(actor(req), 'SELECT item_name AS name, SUM(units_sold) AS units, SUM(revenue) AS revenue FROM mv_item_sales_daily GROUP BY item_name ORDER BY units DESC LIMIT 10') });
}));
router.post('/admin/reports/refresh', admin, wrap(async (req, res) => {
  await query(actor(req), 'REFRESH MATERIALIZED VIEW mv_item_sales_daily'); res.json({ ok: true });
}));
router.post('/admin/settlement', admin, wrap(async (req, res) => {
  const d = new Date(String(req.body.date || '')); if (isNaN(d)) throw bad('Choose a date');
  await run(actor(req), async (c) => { await c.query('CALL sp_daily_settlement($1::date)', [d.toISOString().slice(0, 10)]); });
  res.json({ ok: true });
}));
router.get('/admin/settlements', admin, wrap(async (req, res) => {
  res.json({ rows: await query(actor(req), `SELECT settle_date AS date, orders_count AS orders, gross_sales AS gross, discount_total AS discount, tax_total AS gst,
      net_sales AS net, upi_total AS upi, card_total AS card, cash_total AS cash FROM daily_settlement ORDER BY settle_date DESC LIMIT 30`) });
}));
module.exports = router;
