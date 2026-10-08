// DineFlow API + static front end in one process.
const express = require('express');
const path = require('path');
const { pool } = require('./db');
const { authenticate } = require('./auth');

const app = express();
app.set('trust proxy', 1);                                 // Render sits behind a proxy (correct client IP for rate limiting)
app.disable('x-powered-by');
app.use(express.json({ limit: '20kb' }));                  // request size limit

app.use((req, res, next) => {                              // basic security headers
  res.set({ 'X-Content-Type-Options': 'nosniff', 'X-Frame-Options': 'DENY', 'Referrer-Policy': 'no-referrer',
            'Content-Security-Policy': "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:" });
  const allowed = (process.env.CORS_ORIGINS || '').split(',').map((s) => s.trim()).filter(Boolean);
  if (allowed.includes(req.get('origin'))) {
    res.set({ 'Access-Control-Allow-Origin': req.get('origin'), 'Access-Control-Allow-Headers': 'Content-Type, Authorization', 'Access-Control-Allow-Methods': 'GET,POST,PUT,DELETE,OPTIONS', Vary: 'Origin' });
    if (req.method === 'OPTIONS') return res.sendStatus(204);
  }
  next();
});

app.get('/api/health', async (_req, res) => {
  try { await pool.query('SELECT 1'); res.json({ ok: true }); } catch (_) { res.status(503).json({ ok: false }); }
});
app.use('/api', authenticate, require('./routes/public'), require('./routes/customer'), require('./routes/staff'));
app.use('/api', (_req, res) => res.status(404).json({ error: 'Not found' }));
app.use(express.static(path.join(__dirname, '..', 'public')));
app.use((err, _req, res, _next) => {                       // malformed JSON etc.
  res.status(err.status === 413 ? 413 : 400).json({ error: err.status === 413 ? 'Request too large' : 'Bad request' });
});

const port = process.env.PORT || 3000;
app.listen(port, () => console.log(`DineFlow running at http://localhost:${port}`));
