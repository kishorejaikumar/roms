// Error mapping: browsers only ever get short, safe messages. Raw database errors stay in the server log.
const wrap = (fn) => (req, res, next) => fn(req, res, next).catch((e) => {
  let status = e.status || 500, msg = e.status ? e.message : null;
  switch (e.code) {
    case 'P0001': status = 409; msg = e.message; break;                       // RAISE EXCEPTION written by our triggers/functions
    case '23P01': status = 409; msg = 'That table is already booked for this time'; break;   // exclusion constraint
    case '23505': status = 409; msg = 'That already exists or the table is busy'; break;     // unique violation
    case '23514': status = 400; msg = 'A value is outside the allowed range'; break;         // CHECK
    case '23503': status = 400; msg = 'Unknown reference'; break;                             // foreign key
    case '22P02': case '22003': case '22007': case '22008': status = 400; msg = 'Invalid input'; break;
    case '55P03': status = 409; msg = 'Someone else is working on this right now. Try again.'; break;
    case '40001': case '40P01': status = 503; msg = 'The system was busy. Please try again.'; break;
  }
  if (!msg) { status = 500; msg = 'Server error'; }
  if (status === 500) console.error(e);
  res.status(status).json({ error: msg });
});
const bad = (message, status = 400) => Object.assign(new Error(message), { status });
const int = (v, name) => { const n = Number(v); if (!Number.isInteger(n) || n <= 0) throw bad(`Invalid ${name}`); return n; };
const str = (v, name, max = 120) => { if (typeof v !== 'string' || !v.trim() || v.length > max) throw bad(`Invalid ${name}`); return v.trim(); };
module.exports = { wrap, bad, int, str };
