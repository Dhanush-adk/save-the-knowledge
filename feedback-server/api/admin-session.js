const { isAdminSessionAuthenticated } = require('../lib/security');

module.exports = async (req, res) => {
  if (req.method !== 'GET') {
    res.status(405).end();
    return;
  }
  res.status(200).json({ ok: true, authenticated: isAdminSessionAuthenticated(req) });
};
