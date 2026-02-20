const { validateDashboardPassword, setAdminSessionCookie, checkRateLimit } = require('../lib/security');

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).end();
    return;
  }
  if (!(await checkRateLimit(req, res, 'admin_login', 20))) return;
  try {
    const body = typeof req.body === 'string' ? JSON.parse(req.body) : req.body || {};
    const password = (body.password || '').toString();
    if (!validateDashboardPassword(password)) {
      res.status(401).json({ ok: false, error: 'invalid_credentials' });
      return;
    }
    if (!setAdminSessionCookie(res, req)) {
      res.status(503).json({ ok: false, error: 'session_secret_not_configured' });
      return;
    }
    res.status(200).json({ ok: true, authenticated: true });
  } catch (e) {
    console.error('[admin-login]', e);
    res.status(500).json({ ok: false, error: 'login_failed' });
  }
};
