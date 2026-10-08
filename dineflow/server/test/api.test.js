// End-to-end API checks. Run against a freshly seeded database with the server running:
//   BASE=http://localhost:3000 node test/api.test.js
// (It changes data; re-run the SQL files 01-07 afterwards to reset.)
const BASE = process.env.BASE || 'http://localhost:3000';
let pass = 0, n = 0;
const ok = (name, cond) => { n++; if (cond) pass++; console.log(`${String(n).padStart(2)}  ${cond ? 'PASS' : 'FAIL'}  ${name}`); };
const call = async (method, url, token, body) => {
  const r = await fetch(BASE + '/api' + url, { method, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}) }, body: body ? JSON.stringify(body) : undefined });
  return { s: r.status, j: await r.json().catch(() => ({})) };
};
const tomorrow = (h) => { const d = new Date(); d.setDate(d.getDate() + 5); d.setHours(h, 0, 0, 0); return d.toISOString(); };

(async () => {
  let r = await call('GET', '/health'); ok('health check returns ok', r.s === 200 && r.j.ok === true);
  r = await call('GET', '/menu'); const menu = r.j.items || [];
  const id = (name) => menu.find((m) => m.name === name).id;
  ok('menu has 19 dishes, with ratings and a sold-out flag', menu.length === 19 && menu.find((m) => m.name === 'Crispy Corn').soldOut === true && menu.find((m) => m.name === 'Paneer Tikka').rating == 5);

  const email = `test${Date.now()}@example.in`;
  r = await call('POST', '/auth/register', null, { name: 'Test Diner', email, phone: '9876543210', password: 'Passw0rd!' });
  const me = r.j.token; ok('register returns 201 and a token', r.s === 201 && !!me);
  r = await call('POST', '/auth/register', null, { name: 'Test Diner', email, phone: '9876543210', password: 'Passw0rd!' });
  ok('duplicate email rejected (409, clean message)', r.s === 409 && /already registered/.test(r.j.error));
  r = await call('POST', '/auth/login', null, { email, password: 'wrong-password' }); ok('wrong password gives 401', r.s === 401);
  r = await call('POST', '/auth/login', null, { email: 'vikram.shah@example.in', password: 'Customer@123' }); const vik = r.j.token; ok('seeded customer can log in', r.s === 200 && !!vik);
  r = await call('GET', '/auth/me', me + 'x'); ok('tampered token rejected (401)', r.s === 401);
  r = await call('POST', '/orders', null, { orderType: 'Takeaway', items: [{ itemId: 1, qty: 1 }] }); ok('ordering without signing in gives 401', r.s === 401);

  r = await call('POST', '/orders', me, { orderType: 'Takeaway', items: [{ itemId: id('Masala Chai'), qty: 2 }, { itemId: id('Butter Naan'), qty: 3 }], paymentMethod: 'Cash' });
  const oid = r.j.orderId; ok('place takeaway order (201)', r.s === 201 && !!oid);
  r = await call('GET', '/orders/mine', me); const mine = r.j.orders.find((o) => o.id === oid);
  ok('my orders shows it Placed with total = 265 + 5% GST = 278.25', mine && mine.status === 'Placed' && mine.total === 278.25);
  r = await call('POST', '/orders', me, { orderType: 'Takeaway', items: [{ itemId: id('Masala Chai'), qty: 1, price: 1 }] }); ok('stale price rejected (409)', r.s === 409 && /price/.test(r.j.error));
  r = await call('POST', '/orders', me, { orderType: 'Takeaway', items: [{ itemId: id('Crispy Corn'), qty: 1 }] }); ok('sold-out dish rejected (409)', r.s === 409 && /sold out/.test(r.j.error));
  r = await call('POST', '/coupons/check', me, { code: 'welcome10', subtotal: 800 }); ok('coupon preview: 10% of 800 = 80', r.s === 200 && r.j.discount === 80);
  r = await call('POST', '/coupons/check', me, { code: 'EXPIRED20', subtotal: 800 }); ok('expired coupon rejected (409)', r.s === 409);
  r = await call('GET', '/orders/' + oid, vik); ok("another customer cannot open my order (404)", r.s === 404);
  r = await call('GET', '/kitchen/queue', me); ok('customer cannot open the kitchen display (403)', r.s === 403);

  r = await call('POST', '/auth/staff-login', null, { email: 'kitchen1@dineflow.in', password: 'Kitchen@123' }); const chef = r.j.token; ok('kitchen staff log in', r.s === 200 && r.j.user.role === 'kitchen');
  r = await call('POST', '/auth/staff-login', null, { email: 'admin@dineflow.in', password: 'Admin@123' }); const adm = r.j.token; ok('admin logs in', r.s === 200 && r.j.user.role === 'admin');
  r = await call('GET', '/kitchen/queue', chef); ok('new order appears in the kitchen queue', r.s === 200 && r.j.queue.some((q) => q.id === oid));
  r = await call('POST', `/kitchen/orders/${oid}/status`, chef, { status: 'Paid' }); ok('trigger: kitchen cannot jump Placed -> Paid (409)', r.s === 409 && /Illegal status change/.test(r.j.error));
  r = await call('POST', `/kitchen/orders/${oid}/status`, chef, { status: 'Preparing' }); ok('kitchen moves Placed -> Preparing', r.s === 200);
  r = await call('POST', `/kitchen/orders/${oid}/status`, chef, { status: 'Cancelled' }); ok('trigger: kitchen cannot cancel (409)', r.s === 409);
  r = await call('POST', `/kitchen/orders/${oid}/status`, chef, { status: 'Served' }); ok('kitchen moves Preparing -> Served', r.s === 200);
  r = await call('GET', '/admin/orders?status=Served', adm); const row = r.j.orders.find((o) => o.id === oid);
  ok('admin sees the Served order with a pending cash payment', row && row.pendingPayments && row.pendingPayments.length === 1);
  r = await call('POST', `/admin/payments/${row.pendingPayments[0].id}/confirm`, adm); ok('admin confirms the cash payment', r.s === 200);
  r = await call('GET', '/orders/mine', me); ok('trigger closed the bill automatically: order is Paid', r.j.orders.find((o) => o.id === oid).status === 'Paid');
  r = await call('POST', '/reviews', me, { orderId: oid, itemId: id('Masala Chai'), rating: 5, comment: 'Lovely chai' }); ok('review after a paid order accepted', r.s === 201);
  r = await call('POST', '/reviews', me, { orderId: oid, itemId: id('Masala Chai'), rating: 4 }); ok('second review for the same dish rejected (409)', r.s === 409);
  r = await call('POST', '/reviews', me, { orderId: oid, itemId: id('Paneer Tikka'), rating: 4 }); ok('review for a dish not on the order rejected', r.s === 400);

  // failed payment rolls everything back
  const before = (await call('GET', '/orders/mine', me)).j.orders.length;
  r = await call('POST', '/orders', me, { orderType: 'Takeaway', items: [{ itemId: id('Paneer Tikka'), qty: 1 }], paymentMethod: 'UPI', upiRef: 'fail@okbank' });
  ok('failed UPI payment rejects the order and rolls back', r.s === 409 && (await call('GET', '/orders/mine', me)).j.orders.length === before);

  // reservations (feature B)
  const slot = tomorrow(19);
  r = await call('GET', `/tables/available?start=${encodeURIComponent(slot)}&party=2&minutes=90`); const t = r.j.tables[0]; ok('available tables listed for a slot', r.s === 200 && !!t);
  r = await call('POST', '/reservations', me, { tableId: t.table_id, partySize: 2, start: slot, minutes: 90 }); ok('reservation created (201)', r.s === 201);
  r = await call('POST', '/reservations', vik, { tableId: t.table_id, partySize: 2, start: new Date(new Date(slot).getTime() + 30 * 60000).toISOString(), minutes: 60 });
  ok('overlapping reservation blocked by the database (409)', r.s === 409 && /already booked/.test(r.j.error));

  // concurrency (Unit IV): the last Rasmalai (stock 1) from two customers at once
  const [a, b] = await Promise.all([
    call('POST', '/orders', me,  { orderType: 'Takeaway', items: [{ itemId: id('Rasmalai'), qty: 1 }] }),
    call('POST', '/orders', vik, { orderType: 'Takeaway', items: [{ itemId: id('Rasmalai'), qty: 1 }] })]);
  ok('last dish ordered twice at once: exactly one succeeds', [a.s, b.s].sort().join() === '201,409');
  // same table from two browsers
  const t2 = (await call('GET', '/tables')).j.tables.find((x) => x.no === 'T02').id;
  const [c, d] = await Promise.all([
    call('POST', '/orders', me,  { orderType: 'Dine-in', tableId: t2, items: [{ itemId: id('Butter Naan'), qty: 1 }] }),
    call('POST', '/orders', vik, { orderType: 'Dine-in', tableId: t2, items: [{ itemId: id('Butter Naan'), qty: 1 }] })]);
  ok('same table ordered twice at once: exactly one succeeds', [c.s, d.s].sort().join() === '201,409');

  // admin
  r = await call('GET', '/admin/reports/summary', adm); ok('admin report summary', r.s === 200 && r.j.week.length === 7 && r.j.summary.paid_orders >= 8);
  r = await call('GET', '/admin/reports/summary', me); ok('customer cannot open admin reports (403)', r.s === 403);
  r = await call('GET', '/admin/reports/by?dimension=category', adm); ok('dynamic-SQL report by category', r.s === 200 && r.j.rows.length >= 6);
  r = await call('GET', "/admin/reports/by?dimension=day';DROP TABLE orders;--", adm); ok('SQL injection attempt in report dimension rejected', r.s === 409 || r.s === 400);
  r = await call('POST', '/admin/settlement', adm, { date: new Date(Date.now() - 864e5).toISOString().slice(0, 10) }); ok('cursor settlement procedure runs', r.s === 200);
  r = await call('POST', '/admin/restock-low', adm, { target: 50 }); ok('restock low items', r.s === 200 && r.j.restocked >= 2);
  console.log(`\n${pass} of ${n} checks passed`);
  process.exit(pass === n ? 0 : 1);
})();
