const { createInstallToken, checkRateLimit } = require('../lib/security');

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).end();
    return;
  }
  if (!(await checkRateLimit(req, res, 'register_install', 60))) return;
  try {
    const body = typeof req.body === 'string' ? JSON.parse(req.body) : req.body || {};
    const installId = (body.install_id || '').toString().trim();
    if (!installId || installId.length > 128 || !/^[A-Za-z0-9._:-]+$/.test(installId)) {
      res.status(400).json({ ok: false, error: 'invalid_install_id' });
      return;
    }
    const token = createInstallToken(installId);
    if (!token) {
      res.status(503).json({ ok: false, error: 'token_secret_not_configured' });
      return;
    }
    res.status(200).json({ ok: true, token });
  } catch (e) {
    console.error('[register-install]', e);
    res.status(500).json({ ok: false, error: 'register_failed' });
  }
};
