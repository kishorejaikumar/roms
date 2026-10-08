// Customer routes. The customer id ALWAYS comes from the signed token (req.user.id), never from the body.
const router = require('express').Router();
const { run, query } = require('../db');
const { requireRole } = require('../auth');
const { wrap, bad, int, str } = require('../util');
router.use(['/coupons', '/reservations', '/orders', '/reviews'], requireRole('customer'));   // scoped: staff routes are not affected
const actor = (req) => ({ role: 'customer', id: req.user.id });

// ---- coupons: preview a discount without using it
router.post('/coupons/check', wrap(async (req, res) => {
  const subtotal = Number(req.body.subtotal);
  if (!(subtotal > 0)) throw bad('Add dishes before applying a coupon');
  const out = await run(actor(req), async (c) => {
    const { rows: [r] } = await c.query('SELECT fn_check_coupon($1,$2,$3) AS id', [str(req.body.code, 'coupon', 20), req.user.id, subtotal]);
    const { rows: [d] } = await c.query('SELECT fn_coupon_discount($1,$2) AS discount', [r.id, subtotal]);
    return d.discount;
  });
  res.json({ discount: out });
}));

// ---- reservations (feature B)
router.post('/reservations', wrap(async (req, res) => {
  const start = new Date(String(req.body.start || '')); if (isNaN(start)) throw bad('Choose a valid date and time');
  const [r] = await query(actor(req), 'SELECT fn_reserve_table($1,$2,$3,$4,$5) AS id',
    [req.user.id, int(req.body.tableId, 'table'), int(req.body.partySize, 'party size'), start.toISOString(), Math.min(Math.max(parseInt(req.body.minutes) || 90, 30), 180)]);
  res.status(201).json({ reservationId: r.id });
}));
router.get('/reservations/mine', wrap(async (req, res) => {
  res.json({ reservations: await query(actor(req), `SELECT r.reservation_id AS id, t.table_no AS "tableNo", r.party_size AS "partySize",
      r.start_time AS start, r.end_time AS "end", r.status FROM table_reservations r JOIN restaurant_tables t USING (table_id)
     WHERE r.customer_id = $1 ORDER BY r.start_time DESC LIMIT 30`, [req.user.id]) });
}));
router.post('/reservations/:id/cancel', wrap(async (req, res) => {
  const rows = await query(actor(req), `UPDATE table_reservations SET status = 'Cancelled' WHERE reservation_id = $1 AND customer_id = $2 AND status = 'Booked' RETURNING reservation_id`, [int(req.params.id, 'reservation'), req.user.id]);
  if (!rows.length) throw bad('Reservation not found or cannot be cancelled', 404);
  res.json({ ok: true });
}));

// ---- orders (rule 3): the whole order is ONE database call, ONE transaction
router.post('/orders', wrap(async (req, res) => {
  const b = req.body || {};
  const type = b.orderType === 'Takeaway' ? 'Takeaway' : 'Dine-in';
  if (!Array.isArray(b.items) || !b.items.length || b.items.length > 30) throw bad('Add at least one dish');
  const items = b.items.map((x) => ({ itemId: int(x.itemId, 'dish'), qty: int(x.qty, 'quantity'), note: x.note ? String(x.note).slice(0, 100) : undefined, price: x.price }));
  const method = ['UPI', 'Card', 'Cash'].includes(b.paymentMethod) ? b.paymentMethod : 'Cash';
  const [r] = await query(actor(req), 'SELECT fn_place_order($1,$2,$3,$4::jsonb,$5,$6,$7,$8,$9,$10) AS id', [
    req.user.id, type, type === 'Dine-in' ? int(b.tableId, 'table') : null, JSON.stringify(items),
    b.couponCode ? String(b.couponCode).slice(0, 20) : null, b.reservationId ? int(b.reservationId, 'reservation') : null,
    method, b.upiRef ? String(b.upiRef).slice(0, 40) : null, b.cardLast4 ? String(b.cardLast4).slice(0, 4) : null, b.notes ? String(b.notes).slice(0, 200) : null]);
  res.status(201).json({ orderId: r.id });
}));

router.get('/orders/mine', wrap(async (req, res) => {
  const rows = await query(actor(req), `SELECT h.order_id AS id, h.order_no AS "orderNo", h.order_type AS type, h.table_no AS "tableNo", h.status,
      h.subtotal, h.discount_amt AS discount, h.tax_amt AS gst, h.total_amt AS total, h.created_at AS "createdAt", h.items,
      COALESCE((SELECT SUM(amount) FROM payments p WHERE p.order_id = h.order_id AND p.status = 'Success'), 0) AS paid,
      EXISTS (SELECT 1 FROM order_splits s WHERE s.order_id = h.order_id) AS split
     FROM v_order_history h WHERE h.customer_id = $1 ORDER BY h.created_at DESC LIMIT 50`, [req.user.id]);
  res.json({ orders: rows });
}));

router.get('/orders/:id', wrap(async (req, res) => {
  const id = int(req.params.id, 'order');
  const out = await run(actor(req), async (c) => {
    const { rows: [o] } = await c.query('SELECT * FROM v_order_history WHERE order_id = $1 AND customer_id = $2', [id, req.user.id]);
    if (!o) throw bad('Order not found', 404);
    const lines = (await c.query(`SELECT oi.item_id AS "itemId", m.name, oi.quantity, oi.unit_price AS "unitPrice", oi.line_total AS "lineTotal",
        (SELECT rating FROM reviews r WHERE r.order_id = oi.order_id AND r.item_id = oi.item_id) AS rating
        FROM order_items oi JOIN menu_items m USING (item_id) WHERE oi.order_id = $1 ORDER BY oi.line_no`, [id])).rows;
    const payments = (await c.query('SELECT payment_id AS id, method, amount, status, paid_at AS "paidAt" FROM payments WHERE order_id = $1 ORDER BY payment_id', [id])).rows;
    const splits = (await c.query('SELECT split_no AS "no", payer_name AS name, amount, payment_id IS NOT NULL AS paid FROM order_splits WHERE order_id = $1 ORDER BY split_no', [id])).rows;
    const trail = (await c.query('SELECT from_status AS "from", to_status AS "to", changed_by AS by, changed_at AS at FROM v_order_audit WHERE order_id = $1', [id])).rows;
    return { order: o, lines, payments, splits, trail };
  });
  res.json(out);
}));

router.post('/orders/:id/cancel', wrap(async (req, res) => {
  await query(actor(req), 'SELECT fn_cancel_order($1, $2, $3)', [int(req.params.id, 'order'), 'customer', req.user.id]);
  res.json({ ok: true });
}));

const payArgs = (b) => [['UPI', 'Card', 'Cash'].includes(b.method) ? b.method : 'Cash', b.upiRef ? String(b.upiRef).slice(0, 40) : null, b.cardLast4 ? String(b.cardLast4).slice(0, 4) : null];
router.post('/orders/:id/pay', wrap(async (req, res) => {
  const [r] = await query(actor(req), 'SELECT fn_pay_order($1,$2,$3,$4,$5) AS id', [int(req.params.id, 'order'), req.user.id, ...payArgs(req.body || {})]);
  res.json({ paymentId: r.id });
}));
router.post('/orders/:id/split', wrap(async (req, res) => {
  const names = (req.body.names || []).map((n) => String(n).slice(0, 60));
  await query(actor(req), 'SELECT fn_split_bill($1,$2,$3)', [int(req.params.id, 'order'), req.user.id, names]);
  res.json({ ok: true });
}));
router.post('/orders/:id/split/:no/pay', wrap(async (req, res) => {
  const [r] = await query(actor(req), 'SELECT fn_pay_split($1,$2,$3,$4,$5,$6) AS id', [int(req.params.id, 'order'), int(req.params.no, 'share'), req.user.id, ...payArgs(req.body || {})]);
  res.json({ paymentId: r.id });
}));

// ---- reviews (rule 4)
router.post('/reviews', wrap(async (req, res) => {
  const rating = int(req.body.rating, 'rating');
  await query(actor(req), 'INSERT INTO reviews (order_id, item_id, customer_id, rating, comment) VALUES ($1,$2,$3,$4,$5)',
    [int(req.body.orderId, 'order'), int(req.body.itemId, 'dish'), req.user.id, rating, req.body.comment ? String(req.body.comment).slice(0, 300) : null]);
  res.status(201).json({ ok: true });
}));
module.exports = router;
