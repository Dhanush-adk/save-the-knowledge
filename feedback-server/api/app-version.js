module.exports = async (req, res) => {
  if (req.method !== 'GET') {
    res.status(405).end();
    return;
  }

  const latest = (process.env.APP_LATEST_VERSION || '1.0.0').trim();
  const minimum = (process.env.APP_MINIMUM_VERSION || '').trim();
  const downloadURL = (process.env.APP_DOWNLOAD_URL || '').trim();
  const releaseNotes = (process.env.APP_RELEASE_NOTES || '').trim();

  res.setHeader('Cache-Control', 'public, max-age=300');
  res.status(200).json({
    ok: true,
    latest_version: latest,
    minimum_version: minimum || null,
    download_url: downloadURL || null,
    release_notes: releaseNotes || null,
    timestamp: new Date().toISOString(),
  });
};
