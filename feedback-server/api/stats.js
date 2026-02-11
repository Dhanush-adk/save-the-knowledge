const { readData } = require('../lib/store');

module.exports = async (req, res) => {
  if (req.method !== 'GET') {
    res.status(405).end();
    return;
  }
  try {
    const data = await readData();
    res.setHeader('Cache-Control', 'public, s-maxage=30, stale-while-revalidate=60');
    res.status(200).json(data);
  } catch (e) {
    console.error('[stats]', e);
    res.status(200).json({ analytics: [], feedback: [] });
  }
};
