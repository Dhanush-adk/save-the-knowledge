module.exports = async (req, res) => {
  if (req.method !== 'GET') {
    res.status(405).end();
    return;
  }

  const latest = (process.env.APP_LATEST_VERSION || '1.0.0').trim();
  const minimum = (process.env.APP_MINIMUM_VERSION || '').trim();
  const downloadURL = (process.env.APP_DOWNLOAD_URL || '').trim();
  const releaseNotes = (process.env.APP_RELEASE_NOTES || '').trim();
  const bannerId = (process.env.APP_BANNER_ID || '').trim();
  const bannerText = (process.env.APP_BANNER_TEXT || '').trim();
  const bannerURL = (process.env.APP_BANNER_URL || '').trim();
  const bannerLevel = (process.env.APP_BANNER_LEVEL || 'info').trim().toLowerCase();
  const bannerDismissibleRaw = (process.env.APP_BANNER_DISMISSIBLE || 'true').trim().toLowerCase();
  const bannerStartsAt = (process.env.APP_BANNER_STARTS_AT || '').trim();
  const bannerEndsAt = (process.env.APP_BANNER_ENDS_AT || '').trim();

  const validLevels = new Set(['info', 'success', 'warning', 'critical']);
  const normalizedLevel = validLevels.has(bannerLevel) ? bannerLevel : 'info';
  const bannerDismissible = bannerDismissibleRaw === '1' || bannerDismissibleRaw === 'true' || bannerDismissibleRaw === 'yes';

  const hasActiveBanner = bannerText.length > 0;
  const announcement = hasActiveBanner
    ? {
        id: bannerId || `banner-${Date.now()}`,
        text: bannerText,
        url: bannerURL || null,
        level: normalizedLevel,
        dismissible: bannerDismissible,
        starts_at: bannerStartsAt || null,
        ends_at: bannerEndsAt || null,
      }
    : null;

  res.setHeader('Cache-Control', 'public, max-age=300');
  res.status(200).json({
    ok: true,
    latest_version: latest,
    minimum_version: minimum || null,
    download_url: downloadURL || null,
    release_notes: releaseNotes || null,
    announcement,
    timestamp: new Date().toISOString(),
  });
};
