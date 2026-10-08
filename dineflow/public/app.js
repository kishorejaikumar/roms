'use strict';
// DineFlow front end: plain JavaScript, no framework. All data comes from /api; the database enforces the rules.
const $ = (s, r = document) => r.querySelector(s);
const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const rs = (n) => '₹' + Number(n || 0).toFixed(2);
const when = (t) => new Date(t).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' });
const FLOW = ['Placed', 'Preparing', 'Served', 'Billed', 'Paid'];
const S = { token: localStorage.getItem('df_token'), user: JSON.parse(localStorage.getItem('df_user') || 'null'),
            menu: [], tables: [], cart: {}, coupon: null, form: { type: 'Dine-in', table: '', method: 'Cash', upi: '', card: '', code: '', notes: '' },
            view: 'menu', timer: null };

function toast(m) { const e = $('#toast'); e.textContent = m; e.style.display = 'block'; clearTimeout(toast.t); toast.t = setTimeout(() => (e.style.display = 'none'), 3200); }
async function api(method, url, body) {
  const r = await fetch('/api' + url, { method, headers: { 'Content-Type': 'application/json', ...(S.token ? { Authorization: 'Bearer ' + S.token } : {}) }, body: body ? JSON.stringify(body) : undefined });
  const j = await r.json().catch(() => ({}));
  if (r.status === 401 && S.token) { logout(true); }
  if (!r.ok) throw new Error(j.error || 'Something went wrong');
  return j;
}
const act = (fn) => async (...a) => { try { await fn(...a); } catch (e) { toast(e.message); } };
function setUser(token, user) { S.token = token; S.user = user; localStorage.setItem('df_token', token); localStorage.setItem('df_user', JSON.stringify(user)); }
function logout(silent) { S.token = null; S.user = null; localStorage.removeItem('df_token'); localStorage.removeItem('df_user'); S.cart = {}; if (!silent) toast('Signed out'); go('menu'); }

// ---------------- navigation ----------------
const NAV = { guest: [['menu', 'Menu']], customer: [['menu', 'Menu & cart'], ['reserve', 'Reserve a table'], ['orders', 'My orders']],
              kitchen: [['kitchen', 'Kitchen display']], admin: [['a-orders', 'Orders'], ['kitchen', 'Kitchen'], ['stock', 'Stock & prices'], ['reports', 'Reports']] };
function chrome() {
  const role = S.user ? S.user.role : 'guest';
  $('#nav').innerHTML = NAV[role].map(([v, l]) => `<button data-act="go" data-v="${v}" ${S.view === v ? 'aria-current="page"' : ''}>${l}</button>`).join('');
  $('#who').innerHTML = S.user ? `<span>${esc(S.user.name)} · ${esc(S.user.role)}</span><button class="btn alt sm" data-act="logout">Sign out</button>`
                               : `<button class="btn sm" data-act="go" data-v="auth">Sign in</button><button class="btn alt sm" data-act="go" data-v="staff">Staff</button>`;
}
async function go(view) {
  clearInterval(S.timer); S.view = view; chrome();
  const main = $('#app'); main.innerHTML = '<p class="mute">Loading…</p>';
  try {
    const v = VIEWS[view]; main.innerHTML = await v();
    if (v.poll) S.timer = setInterval(async () => { if (S.view === view && !$('#dlg').open && !['INPUT', 'SELECT', 'TEXTAREA'].includes(document.activeElement.tagName)) { try { main.innerHTML = await v(); } catch (_) {} } }, 5000);
  } catch (e) { main.innerHTML = `<div class="card">Could not load this page: ${esc(e.message)}</div>`; }
}
const statusTag = (s) => `<span class="tag st-${esc(s)}">${esc(s)}</span>`;
const steps = (s) => `<div class="steps">${s === 'Cancelled' ? '<span class="on">Cancelled</span>' : FLOW.map((x) => `<span class="${FLOW.indexOf(x) <= FLOW.indexOf(s) ? 'on' : ''}">${x}</span>`).join('')}</div>`;

// ---------------- views ----------------
const VIEWS = {};
VIEWS.menu = async () => {
  S.menu = (await api('GET', '/menu')).items;
  if (S.user && S.user.role === 'customer') S.tables = (await api('GET', '/tables')).tables;
  const cats = [...new Set(S.menu.map((m) => m.category))];
  const list = cats.map((c) => `<h2>${esc(c)}</h2><div class="grid">${S.menu.filter((m) => m.category === c).map(dish).join('')}</div>`).join('');
  return `<div class="hero"><h1>Order from your table or take it away</h1><p class="mute">Sign in, add dishes, apply a coupon and pay by UPI, card or cash.</p></div>
    <div class="cols"><section>${list}</section><aside>${cartPanel()}</aside></div>`;
};
function dish(m) {
  const q = S.cart[m.id] || 0;
  return `<article class="card dish"><div class="row"><h3><span class="dot ${m.veg ? '' : 'nv'}"></span>${esc(m.name)}</h3><span class="price">${rs(m.price)}</span></div>
    <p class="mute">${esc(m.description || '')}</p>
    <div class="row"><span class="mute">${m.reviews > 0 ? '★ ' + m.rating + ' (' + m.reviews + ')' : 'No ratings yet'}${m.soldOut ? ' · <b style="color:var(--bad)">Sold out</b>' : m.stock <= 10 ? ' · only ' + m.stock + ' left' : ''}</span>
    <div class="qty"><button data-act="dec" data-id="${m.id}" aria-label="Remove one ${esc(m.name)}">−</button><span>${q}</span><button data-act="inc" data-id="${m.id}" aria-label="Add one ${esc(m.name)}" ${m.soldOut ? 'disabled' : ''}>+</button></div></div></article>`;
}
function totals() {
  const sub = Object.entries(S.cart).reduce((a, [id, q]) => a + q * S.menu.find((m) => m.id == id).price, 0);
  const disc = S.coupon ? Math.min(S.coupon.discount, sub) : 0, tax = Math.round((sub - disc) * 5) / 100;
  return { sub, disc, tax, total: sub - disc + tax };
}
function cartPanel() {
  const n = Object.values(S.cart).reduce((a, b) => a + b, 0), t = totals(), f = S.form;
  if (!S.user) return `<div class="card"><h2>Your order</h2><p class="mute">Sign in to order.</p><button class="btn" data-act="go" data-v="auth">Sign in or register</button></div>`;
  if (S.user.role !== 'customer') return `<div class="card"><h2>Staff account</h2><p class="mute">Use a customer account to place orders.</p></div>`;
  const lines = Object.entries(S.cart).map(([id, q]) => { const m = S.menu.find((x) => x.id == id); return `<div class="row"><span>${q} × ${esc(m.name)}</span><span>${rs(q * m.price)}</span></div>`; }).join('') || '<p class="mute">Your cart is empty.</p>';
  return `<div class="card sum"><h2>Your order</h2>${lines}
    <label for="f-type">Order type</label><select id="f-type" data-f="type"><option ${f.type === 'Dine-in' ? 'selected' : ''}>Dine-in</option><option ${f.type === 'Takeaway' ? 'selected' : ''}>Takeaway</option></select>
    ${f.type === 'Dine-in' ? `<label for="f-table">Table</label><select id="f-table" data-f="table"><option value="">Choose a free table</option>${S.tables.map((t) => `<option value="${t.id}" ${f.table == t.id ? 'selected' : ''}>${esc(t.no)} · ${t.capacity} seats · ${esc(t.area)}</option>`).join('')}</select>` : ''}
    <label for="f-code">Coupon code</label><div class="row"><input id="f-code" data-f="code" value="${esc(f.code)}" placeholder="e.g. WELCOME10" maxlength="20"><button class="btn alt sm" data-act="coupon">Apply</button></div>
    <label for="f-method">Pay by</label><select id="f-method" data-f="method">${['Cash', 'UPI', 'Card'].map((m) => `<option ${f.method === m ? 'selected' : ''}>${m}</option>`).join('')}</select>
    ${f.method === 'UPI' ? `<label for="f-upi">UPI id</label><input id="f-upi" data-f="upi" value="${esc(f.upi)}" placeholder="name@okbank">` : ''}
    ${f.method === 'Card' ? `<label for="f-card">Last 4 digits of card</label><input id="f-card" data-f="card" value="${esc(f.card)}" inputmode="numeric" maxlength="4">` : ''}
    ${f.method === 'Cash' ? '<p class="mute">Pay at the counter; staff confirm your cash payment.</p>' : ''}
    <label for="f-notes">Notes for the kitchen</label><input id="f-notes" data-f="notes" value="${esc(f.notes)}" maxlength="200">
    <div style="margin-top:12px"><div class="row"><span>Subtotal</span><span>${rs(t.sub)}</span></div>
    ${S.coupon ? `<div class="row"><span>Coupon ${esc(S.coupon.code)}</span><span>−${rs(t.disc)}</span></div>` : ''}
    <div class="row"><span>GST 5%</span><span>${rs(t.tax)}</span></div><div class="row tot"><span>Total</span><span>${rs(t.total)}</span></div></div>
    <p class="mute">The database recalculates the final total when the order is saved.</p>
    <button class="btn" style="width:100%" data-act="place" ${n ? '' : 'disabled'}>Place order</button></div>`;
}

VIEWS.auth = async () => `<div class="cols"><section class="card"><div class="tabs"><button class="btn alt" data-act="tab" data-t="in">Sign in</button><button class="btn alt" data-act="tab" data-t="up">Register</button></div>
  <div id="auth-in"><h2>Sign in</h2><label for="li-e">Email</label><input id="li-e" type="email" autocomplete="username"><label for="li-p">Password</label><input id="li-p" type="password" autocomplete="current-password"><br><br><button class="btn" data-act="login">Sign in</button>
  <p class="mute">Demo: asha.rao@example.in / Customer@123</p></div>
  <div id="auth-up" hidden><h2>Create an account</h2><label for="re-n">Full name</label><input id="re-n" autocomplete="name"><label for="re-e">Email</label><input id="re-e" type="email" autocomplete="email"><label for="re-ph">Phone (10 digits)</label><input id="re-ph" inputmode="numeric" maxlength="10"><label for="re-p">Password (8+ characters)</label><input id="re-p" type="password" autocomplete="new-password"><br><br><button class="btn" data-act="register">Register</button></div></section></div>`;
VIEWS.staff = async () => `<div class="card" style="max-width:420px"><h2>Staff sign in</h2><label for="st-e">Email</label><input id="st-e" type="email"><label for="st-p">Password</label><input id="st-p" type="password"><br><br><button class="btn" data-act="staff-login">Sign in</button>
  <p class="mute">Demo: admin@dineflow.in / Admin@123, kitchen1@dineflow.in / Kitchen@123</p></div>`;

VIEWS.reserve = async () => {
  const mine = (await api('GET', '/reservations/mine')).reservations;
  const dt = new Date(Date.now() + 864e5); dt.setMinutes(0, 0, 0); const v = new Date(dt - dt.getTimezoneOffset() * 6e4).toISOString().slice(0, 16);
  return `<h1>Reserve a table</h1><div class="cols"><section class="card"><label for="rv-t">Date and time</label><input id="rv-t" type="datetime-local" value="${v}">
    <label for="rv-p">Guests</label><input id="rv-p" type="number" min="1" max="20" value="2"><label for="rv-m">Duration</label><select id="rv-m"><option value="60">1 hour</option><option value="90" selected>1.5 hours</option><option value="120">2 hours</option></select><br><br>
    <button class="btn" data-act="find">Find free tables</button><div id="rv-list" style="margin-top:12px"></div></section>
    <aside class="card"><h2>My reservations</h2>${mine.length ? mine.map((r) => `<div class="row" style="padding:6px 0"><span>${esc(r.tableNo)} · ${r.partySize} guests<br><span class="mute">${when(r.start)}</span></span><span>${statusTag(r.status)} ${r.status === 'Booked' ? `<button class="btn alt sm" data-act="rv-cancel" data-id="${r.id}">Cancel</button>` : ''}</span></div>`).join('') : '<p class="mute">None yet.</p>'}</aside></div>`;
};

VIEWS.orders = async () => {
  const os = (await api('GET', '/orders/mine')).orders;
  return `<h1>My orders</h1>${os.length ? os.map((o) => `<article class="card" style="margin-bottom:10px"><div class="row"><b>#${o.orderNo} · ${esc(o.type)}${o.tableNo !== '-' ? ' · ' + esc(o.tableNo) : ''}</b>${statusTag(o.status)}</div>
    ${steps(o.status)}<p>${esc(o.items)}</p><div class="row"><span class="mute">${when(o.createdAt)}</span><b>${rs(o.total)}</b></div>
    <div class="row" style="margin-top:8px;justify-content:flex-start;flex-wrap:wrap"><button class="btn alt sm" data-act="detail" data-id="${o.id}">Details & rating</button>
    ${['Placed', 'Preparing'].includes(o.status) ? `<button class="btn bad sm" data-act="cancel" data-id="${o.id}">Cancel</button>` : ''}
    ${!['Paid', 'Cancelled'].includes(o.status) && o.paid < o.total && !o.split ? `<button class="btn sm" data-act="pay" data-id="${o.id}">Pay now</button><button class="btn alt sm" data-act="split" data-id="${o.id}">Split bill</button>` : ''}</div></article>`).join('') : '<p class="mute">You have not ordered yet.</p>'}`;
};
VIEWS.orders.poll = true;

VIEWS.kitchen = async () => {
  const q = (await api('GET', '/kitchen/queue')).queue;
  const col = (st, label, next, nextTo) => `<section><h2>${label} (${q.filter((x) => x.status === st).length})</h2>${q.filter((x) => x.status === st).map((o) => `<div class="card tk ${esc(o.flag)}"><div class="row"><b>${esc(o.tableNo)} · #${o.orderNo}</b><span>${o.minutes} min</span></div><p>${esc(o.items)}</p>
    <button class="btn" data-act="kstatus" data-id="${o.id}" data-to="${nextTo}">${next}</button></div>`).join('') || '<p class="mute">Nothing here.</p>'}</section>`;
  return `<h1>Kitchen display</h1><p class="mute">Green under 15 min, amber 15–24, red 25+. Refreshes every 5 seconds.</p><div class="kds">${col('Placed', 'New', 'Start cooking', 'Preparing')}${col('Preparing', 'Cooking', 'Mark served', 'Served')}</div>`;
};
VIEWS.kitchen.poll = true;

VIEWS['a-orders'] = async () => {
  const f = S.adminFilter || '';
  const os = (await api('GET', '/admin/orders' + (f ? '?status=' + f : ''))).orders;
  const next = { Placed: ['Preparing'], Preparing: ['Served'], Served: ['Billed'] };
  return `<h1>Orders</h1><label for="af">Status</label><select id="af" data-admin-filter style="max-width:220px"><option value="">All</option>${[...FLOW, 'Cancelled'].map((s) => `<option ${f === s ? 'selected' : ''}>${s}</option>`).join('')}</select>
  <div class="card scroll" style="margin-top:10px"><table><thead><tr><th>#</th><th>Customer</th><th>Where</th><th>Status</th><th>Total</th><th>Paid</th><th>Actions</th></tr></thead><tbody>${os.map((o) => `<tr><td>${o.orderNo}</td><td>${esc(o.customer)}</td><td>${esc(o.type)} ${o.tableNo !== '-' ? esc(o.tableNo) : ''}</td><td>${statusTag(o.status)}</td><td>${rs(o.total)}</td><td>${rs(o.paid)}</td>
   <td>${(next[o.status] || []).map((s) => `<button class="btn sm" data-act="kstatus" data-id="${o.id}" data-to="${s}">${s}</button>`).join(' ')}
   ${['Placed', 'Preparing'].includes(o.status) ? `<button class="btn bad sm" data-act="kstatus" data-id="${o.id}" data-to="Cancelled">Cancel</button>` : ''}
   ${(o.pendingPayments || []).map((p) => `<button class="btn alt sm" data-act="confirm" data-id="${p.id}">Confirm ${esc(p.method)} ${rs(p.amount)}</button>`).join(' ')}
   <button class="btn alt sm" data-act="audit" data-id="${o.id}">Audit</button></td></tr>`).join('')}</tbody></table></div>`;
};
VIEWS['a-orders'].poll = true;

VIEWS.stock = async () => {
  const low = (await api('GET', '/admin/low-stock')).items, menu = (await api('GET', '/menu')).items;
  return `<h1>Stock & prices</h1><div class="cols"><section class="card"><div class="row"><h2>Low stock</h2><button class="btn sm" data-act="restock-low">Top up all to 50</button></div>
    ${low.length ? low.map((i) => `<div class="row" style="padding:6px 0"><span>${esc(i.name)} <span class="mute">(${esc(i.category)})</span><br><b>${i.stock}</b> left ${i.soldOut ? '· <span style="color:var(--bad)">sold out</span>' : ''}</span>
      <span class="row"><input type="number" min="1" value="20" style="width:80px" id="rs-${i.id}" aria-label="Quantity to add to ${esc(i.name)}"><button class="btn sm" data-act="restock" data-id="${i.id}">Add</button></span></div>`).join('') : '<p class="mute">All dishes are above their reorder level.</p>'}</section>
    <aside class="card"><h2>Menu prices</h2>${menu.map((m) => `<div class="row" style="padding:4px 0"><label for="pr-${m.id}" style="margin:0;color:var(--ink)">${esc(m.name)}</label><input id="pr-${m.id}" type="number" min="1" value="${m.price}" data-price="${m.id}" style="width:100px"></div>`).join('')}</aside></div>`;
};

VIEWS.reports = async () => {
  const r = await api('GET', '/admin/reports/summary'), s = r.summary, max = Math.max(1, ...r.week.map((d) => d.net));
  const st = (await api('GET', '/admin/settlements')).rows, items = (await api('GET', '/admin/reports/item-sales')).rows;
  const dim = S.dim || 'category', by = (await api('GET', '/admin/reports/by?dimension=' + dim)).rows;
  return `<h1>Reports</h1><div class="kpis"><div class="card kpi"><span class="mute">Revenue</span><b>${rs(s.revenue)}</b></div><div class="card kpi"><span class="mute">Paid orders</span><b>${s.paid_orders}</b></div><div class="card kpi"><span class="mute">Average order</span><b>${rs(s.avg_order_value)}</b></div><div class="card kpi"><span class="mute">Open orders · low stock · rating</span><b>${s.open_orders} · ${s.low_stock_items} · ${s.avg_rating ?? '-'}</b></div></div>
  <div class="cols"><section class="card"><h2>Last 7 days (net sales)</h2>${r.week.map((d) => `<div class="row"><span style="width:90px">${new Date(d.date).toLocaleDateString([], { day: 'numeric', month: 'short' })}</span><div style="flex:1"><div class="bar" style="width:${Math.round(d.net / max * 100)}%"></div></div><span style="width:90px;text-align:right">${rs(d.net)}</span></div>`).join('')}
    <h2>Peak hours</h2>${r.peak.slice(0, 5).map((p) => `<div class="row"><span>${String(p.hour).padStart(2, '0')}:00</span><span>${p.orders} orders · ${rs(p.net)}</span></div>`).join('')}</section>
  <aside class="card"><h2>Top dishes</h2>${r.top.map((t, i) => `<div class="row"><span>${i + 1}. ${esc(t.name)}</span><span>${t.units} · ${rs(t.revenue)}</span></div>`).join('')}
    <div class="row"><h2>From the materialised view</h2><button class="btn alt sm" data-act="mv-refresh">Refresh</button></div>${items.slice(0, 5).map((t) => `<div class="row"><span>${esc(t.name)}</span><span>${t.units}</span></div>`).join('') || '<p class="mute">Empty: press Refresh.</p>'}</aside></div>
  <section class="card" style="margin-top:14px"><div class="row"><h2>Sales breakdown (dynamic SQL)</h2><select id="dim" data-dim style="max-width:180px">${['category', 'day', 'hour', 'type'].map((d) => `<option ${dim === d ? 'selected' : ''}>${d}</option>`).join('')}</select></div>
    ${by.map((b) => `<div class="row"><span>${esc(b.bucket)}</span><span>${b.orders} orders · ${rs(b.sales)}</span></div>`).join('') || '<p class="mute">No paid orders in the last 30 days.</p>'}</section>
  <section class="card" style="margin-top:14px"><h2>End-of-day settlement (cursor procedure)</h2><div class="row" style="justify-content:flex-start"><input id="sd" type="date" style="max-width:200px" value="${new Date(Date.now() - 864e5).toISOString().slice(0, 10)}"><button class="btn" data-act="settle">Run settlement</button></div>
    <div class="scroll"><table><thead><tr><th>Date</th><th>Orders</th><th>Gross</th><th>Discount</th><th>GST</th><th>Net</th><th>UPI</th><th>Card</th><th>Cash</th></tr></thead><tbody>${st.map((x) => `<tr><td>${esc(String(x.date).slice(0, 10))}</td><td>${x.orders}</td><td>${rs(x.gross)}</td><td>${rs(x.discount)}</td><td>${rs(x.gst)}</td><td><b>${rs(x.net)}</b></td><td>${rs(x.upi)}</td><td>${rs(x.card)}</td><td>${rs(x.cash)}</td></tr>`).join('')}</tbody></table></div></section>`;
};

// ---------------- dialogs ----------------
const dlg = $('#dlg');
function modal(html) { dlg.innerHTML = html + '<div style="margin-top:12px"><button class="btn alt sm" data-act="close">Close</button></div>'; if (!dlg.open) dlg.showModal(); }
const payFields = (id) => `<label for="${id}m">Pay by</label><select id="${id}m" data-paym="${id}"><option>UPI</option><option>Card</option><option>Cash</option></select>
  <div id="${id}u"><label for="${id}ui">UPI id</label><input id="${id}ui" placeholder="name@okbank"></div><div id="${id}c" hidden><label for="${id}ci">Last 4 digits of card</label><input id="${id}ci" maxlength="4" inputmode="numeric"></div>`;
const payBody = (id) => ({ method: $(`#${id}m`).value, upiRef: $(`#${id}ui`).value.trim(), cardLast4: $(`#${id}ci`).value.trim() });

// ---------------- events ----------------
const H = {
  go: (b) => go(b.dataset.v), logout: () => logout(), close: () => dlg.close(),
  tab: (b) => { $('#auth-in').hidden = b.dataset.t !== 'in'; $('#auth-up').hidden = b.dataset.t !== 'up'; },
  login: act(async () => { const r = await api('POST', '/auth/login', { email: $('#li-e').value, password: $('#li-p').value }); setUser(r.token, r.user); toast('Welcome, ' + r.user.name); go('menu'); }),
  register: act(async () => { const r = await api('POST', '/auth/register', { name: $('#re-n').value, email: $('#re-e').value, phone: $('#re-ph').value, password: $('#re-p').value }); setUser(r.token, r.user); toast('Account created'); go('menu'); }),
  'staff-login': act(async () => { const r = await api('POST', '/auth/staff-login', { email: $('#st-e').value, password: $('#st-p').value }); setUser(r.token, r.user); go(r.user.role === 'admin' ? 'a-orders' : 'kitchen'); }),
  inc: (b) => { const m = S.menu.find((x) => x.id == b.dataset.id); if ((S.cart[m.id] || 0) < Math.min(m.stock, 20)) S.cart[m.id] = (S.cart[m.id] || 0) + 1; else toast('No more stock of ' + m.name); S.coupon = null; keepScroll(); },
  dec: (b) => { const id = b.dataset.id; if (S.cart[id]) S.cart[id]--; if (!S.cart[id]) delete S.cart[id]; S.coupon = null; keepScroll(); },
  coupon: act(async () => { const t = totals(); const r = await api('POST', '/coupons/check', { code: S.form.code, subtotal: t.sub }); S.coupon = { code: S.form.code.toUpperCase(), discount: r.discount }; toast('Coupon applied: −' + rs(r.discount)); keepScroll(); }),
  place: act(async () => {
    const f = S.form; if (f.type === 'Dine-in' && !f.table) throw new Error('Choose a table');
    const items = Object.entries(S.cart).map(([id, qty]) => ({ itemId: +id, qty, price: S.menu.find((m) => m.id == id).price }));
    await api('POST', '/orders', { orderType: f.type, tableId: f.type === 'Dine-in' ? +f.table : undefined, items, couponCode: S.coupon ? S.coupon.code : undefined, paymentMethod: f.method, upiRef: f.upi, cardLast4: f.card, notes: f.notes });
    S.cart = {}; S.coupon = null; S.form.code = ''; toast('Order placed. Track it in My orders.'); go('orders');
  }),
  find: act(async () => { const t = $('#rv-t').value; if (!t) throw new Error('Choose a date and time'); S.rv = { start: new Date(t).toISOString(), party: +$('#rv-p').value, minutes: +$('#rv-m').value };
    const r = await api('GET', `/tables/available?start=${encodeURIComponent(S.rv.start)}&party=${S.rv.party}&minutes=${S.rv.minutes}`);
    $('#rv-list').innerHTML = r.tables.length ? r.tables.map((x) => `<div class="row" style="padding:5px 0"><span>${esc(x.table_no)} · ${x.capacity} seats · ${esc(x.area)}</span><button class="btn sm" data-act="reserve" data-id="${x.table_id}">Reserve</button></div>`).join('') : '<p class="mute">No free table for that time.</p>'; }),
  reserve: act(async (b) => { await api('POST', '/reservations', { tableId: +b.dataset.id, partySize: S.rv.party, start: S.rv.start, minutes: S.rv.minutes }); toast('Table reserved'); go('reserve'); }),
  'rv-cancel': act(async (b) => { await api('POST', `/reservations/${b.dataset.id}/cancel`); go('reserve'); }),
  cancel: act(async (b) => { if (confirm('Cancel this order?')) { await api('POST', `/orders/${b.dataset.id}/cancel`); toast('Order cancelled'); go('orders'); } }),
  pay: (b) => modal(`<h2>Pay for your order</h2>${payFields('pp')}<br><button class="btn" data-act="pay-go" data-id="${b.dataset.id}">Pay</button>`),
  'pay-go': act(async (b) => { await api('POST', `/orders/${b.dataset.id}/pay`, payBody('pp')); dlg.close(); toast('Payment recorded'); go('orders'); }),
  split: (b) => modal(`<h2>Split the bill</h2><label for="sp-n">One name per line (2 to 10 diners)</label><textarea id="sp-n" rows="4">Me\nFriend</textarea><br><button class="btn" data-act="split-go" data-id="${b.dataset.id}">Split equally</button>`),
  'split-go': act(async (b) => { await api('POST', `/orders/${b.dataset.id}/split`, { names: $('#sp-n').value.split('\n').map((x) => x.trim()).filter(Boolean) }); dlg.close(); H.detail(b); }),
  detail: act(async (b) => {
    const d = await api('GET', '/orders/' + b.dataset.id), o = d.order;
    modal(`<h2>Order #${o.order_no} ${statusTag(o.status)}</h2>${steps(o.status)}
      ${d.lines.map((l) => `<div class="row" style="padding:3px 0"><span>${l.quantity} × ${esc(l.name)}</span><span>${rs(l.lineTotal)}${o.status === 'Paid' ? (l.rating ? ' · ★' + l.rating : ` <button class="btn alt sm" data-act="rate" data-o="${o.order_id}" data-i="${l.itemId}">Rate</button>`) : ''}</span></div>`).join('')}
      <div class="sum"><div class="row"><span>Subtotal</span><span>${rs(o.subtotal)}</span></div>${o.discount_amt > 0 ? `<div class="row"><span>Discount</span><span>−${rs(o.discount_amt)}</span></div>` : ''}<div class="row"><span>GST</span><span>${rs(o.tax_amt)}</span></div><div class="row tot"><span>Total</span><span>${rs(o.total_amt)}</span></div></div>
      ${d.splits.length ? `<h3 style="margin-top:12px">Shares</h3>${d.splits.map((s) => `<div class="row"><span>${esc(s.name)} · ${rs(s.amount)}</span>${s.paid ? '<span class="tag st-Paid">Paid</span>' : `<button class="btn sm" data-act="share" data-o="${o.order_id}" data-n="${s.no}">Pay share</button>`}</div>`).join('')}` : ''}
      <h3 style="margin-top:12px">Payments</h3>${d.payments.map((p) => `<div class="row"><span>${esc(p.method)} · ${rs(p.amount)}</span><span class="mute">${esc(p.status)}</span></div>`).join('') || '<p class="mute">None yet.</p>'}
      <h3 style="margin-top:12px">History</h3>${d.trail.map((t) => `<div class="mute">${esc(t.from)} → ${esc(t.to)} by ${esc(t.by)} · ${when(t.at)}</div>`).join('')}`);
  }),
  share: (b) => modal(`<h2>Pay your share</h2>${payFields('ps')}<br><button class="btn" data-act="share-go" data-o="${b.dataset.o}" data-n="${b.dataset.n}">Pay</button>`),
  'share-go': act(async (b) => { await api('POST', `/orders/${b.dataset.o}/split/${b.dataset.n}/pay`, payBody('ps')); dlg.close(); toast('Share paid'); go('orders'); }),
  rate: (b) => modal(`<h2>Rate this dish</h2><label for="rt">Stars</label><select id="rt"><option>5</option><option>4</option><option>3</option><option>2</option><option>1</option></select><label for="rc">Comment (optional)</label><input id="rc" maxlength="300"><br><br><button class="btn" data-act="rate-go" data-o="${b.dataset.o}" data-i="${b.dataset.i}">Submit</button>`),
  'rate-go': act(async (b) => { await api('POST', '/reviews', { orderId: +b.dataset.o, itemId: +b.dataset.i, rating: +$('#rt').value, comment: $('#rc').value }); dlg.close(); toast('Thanks for rating'); go('orders'); }),
  kstatus: act(async (b) => { await api('POST', `/kitchen/orders/${b.dataset.id}/status`, { status: b.dataset.to }); go(S.view); }),
  confirm: act(async (b) => { await api('POST', `/admin/payments/${b.dataset.id}/confirm`); toast('Payment confirmed'); go(S.view); }),
  audit: act(async (b) => { const r = await api('GET', '/admin/audit/' + b.dataset.id); modal(`<h2>Audit trail</h2>${r.trail.map((t) => `<div class="row"><span>${esc(t.from)} → ${esc(t.to)}</span><span class="mute">${esc(t.by)} · ${when(t.at)}</span></div>`).join('') || '<p class="mute">No changes yet.</p>'}`); }),
  restock: act(async (b) => { await api('POST', '/admin/restock', { itemId: +b.dataset.id, qty: +$('#rs-' + b.dataset.id).value }); toast('Restocked'); go('stock'); }),
  'restock-low': act(async () => { const r = await api('POST', '/admin/restock-low', { target: 50 }); toast(r.restocked + ' dishes topped up'); go('stock'); }),
  settle: act(async () => { await api('POST', '/admin/settlement', { date: $('#sd').value }); toast('Settlement saved'); go('reports'); }),
  'mv-refresh': act(async () => { await api('POST', '/admin/reports/refresh'); toast('Report refreshed'); go('reports'); })
};
function keepScroll() { const y = scrollY; $('#app').querySelector('aside').innerHTML = cartPanel(); const secs = $('#app section'); if (secs) { /* refresh dish quantities */ const cats = [...new Set(S.menu.map((m) => m.category))]; secs.innerHTML = cats.map((c) => `<h2>${esc(c)}</h2><div class="grid">${S.menu.filter((m) => m.category === c).map(dish).join('')}</div>`).join(''); } scrollTo(0, y); }

document.addEventListener('click', (e) => { const b = e.target.closest('[data-act]'); if (b && H[b.dataset.act]) H[b.dataset.act](b); });
document.addEventListener('input', (e) => { const k = e.target.dataset.f; if (k) S.form[k] = e.target.value; });
document.addEventListener('change', act(async (e) => {
  const t = e.target;
  if (t.dataset.f === 'type' || t.dataset.f === 'method') { S.form[t.dataset.f] = t.value; keepScroll(); }
  else if (t.dataset.paym) { const id = t.dataset.paym; $(`#${id}u`).hidden = t.value !== 'UPI'; $(`#${id}c`).hidden = t.value !== 'Card'; }
  else if (t.hasAttribute('data-admin-filter')) { S.adminFilter = t.value; go('a-orders'); }
  else if (t.dataset.dim !== undefined) { S.dim = t.value; go('reports'); }
  else if (t.dataset.price) { await api('PUT', '/admin/menu/' + t.dataset.price, { price: +t.value }); toast('Price saved'); }
}));
chrome(); go(S.user ? { customer: 'menu', kitchen: 'kitchen', admin: 'a-orders' }[S.user.role] : 'menu');
