const { clearAdminSessionCookie } = require('../lib/security');

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).end();
    return;
  }
  clearAdminSessionCookie(res, req);
  res.status(200).json({ ok: true, authenticated: false });
};
