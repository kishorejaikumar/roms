// HMAC-SHA256 signed tokens (no external library), role middleware and a login rate limiter.
const crypto = require('crypto');
const SECRET = process.env.TOKEN_SECRET || '';
if (SECRET.length < 16) { console.error('TOKEN_SECRET must be set to a long random string (see .env.example).'); process.exit(1); }

const b64 = (b) => Buffer.from(b).toString('base64url');
const sign = (data) => crypto.createHmac('sha256', SECRET).update(data).digest('base64url');

function makeToken(user, ttlSeconds = 8 * 3600) {
  const payload = b64(JSON.stringify({ id: user.id, role: user.role, name: user.name, exp: Math.floor(Date.now() / 1000) + ttlSeconds }));
  return `${payload}.${sign(payload)}`;
}
function readToken(token) {
  const [payload, sig] = String(token || '').split('.');
  if (!payload || !sig) return null;
  const good = Buffer.from(sign(payload)), given = Buffer.from(sig);
  if (good.length !== given.length || !crypto.timingSafeEqual(good, given)) return null;   // constant-time compare
  try {
    const p = JSON.parse(Buffer.from(payload, 'base64url').toString());
    return p.exp > Date.now() / 1000 ? p : null;
  } catch (_) { return null; }
}

// attaches req.user = {id, role, name}. The customer id ALWAYS comes from here, never from the request body.
function authenticate(req, _res, next) {
  const h = req.get('authorization') || '';
  req.user = h.startsWith('Bearer ') ? readToken(h.slice(7)) : null;
  next();
}
const requireRole = (...roles) => (req, res, next) => {
  if (!req.user) return res.status(401).json({ error: 'Please sign in' });
  if (!roles.includes(req.user.role)) return res.status(403).json({ error: 'You are not allowed to do this' });
  next();
};

// Login rate limit: 5 failures per 15 minutes per (ip + email); success clears the counter.
const fails = new Map();
const WINDOW = 15 * 60 * 1000, MAX = 5;
function limiter(req, res, next) {
  const key = `${req.ip}|${String((req.body && req.body.email) || '').toLowerCase()}`;
  const now = Date.now(), rec = fails.get(key);
  if (rec && now - rec.first < WINDOW && rec.n >= MAX) return res.status(429).json({ error: 'Too many failed attempts. Try again in a few minutes.' });
  req.rateKey = key;
  req.loginFailed = () => { const r = fails.get(key); (!r || now - r.first >= WINDOW) ? fails.set(key, { n: 1, first: now }) : r.n++; };
  req.loginOk = () => fails.delete(key);
  next();
}
setInterval(() => { const t = Date.now(); for (const [k, v] of fails) if (t - v.first > WINDOW) fails.delete(k); }, 60000).unref();

module.exports = { makeToken, readToken, authenticate, requireRole, limiter };
