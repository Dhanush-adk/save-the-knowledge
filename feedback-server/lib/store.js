const BLOB_PATH = 'kc/data.json';
const MAX_ANALYTICS = 200;
const MAX_FEEDBACK = 200;

async function getBlobClient() {
  try {
    const { put, list } = await import('@vercel/blob');
    return { put, list };
  } catch (e) {
    return null;
  }
}

async function readData() {
  const client = await getBlobClient();
  if (!client || !process.env.BLOB_READ_WRITE_TOKEN) {
    return { analytics: [], feedback: [] };
  }
  try {
    const { list } = client;
    const { blobs } = await list({ prefix: 'kc/' });
    const dataBlob = blobs.find((b) => b.pathname === BLOB_PATH);
    if (!dataBlob?.url) return { analytics: [], feedback: [] };
    const res = await fetch(dataBlob.url);
    if (!res.ok) return { analytics: [], feedback: [] };
    const json = await res.json();
    return {
      analytics: Array.isArray(json.analytics) ? json.analytics : [],
      feedback: Array.isArray(json.feedback) ? json.feedback : [],
    };
  } catch (e) {
    console.error('[store] read', e);
    return { analytics: [], feedback: [] };
  }
}

async function writeData(data) {
  const client = await getBlobClient();
  if (!client || !process.env.BLOB_READ_WRITE_TOKEN) return;
  try {
    const { put } = client;
    await put(BLOB_PATH, JSON.stringify(data), {
      access: 'public',
      addRandomSuffix: false,
      contentType: 'application/json',
      allowOverwrite: true,
    });
  } catch (e) {
    console.error('[store] write', e);
  }
}

async function appendAnalytics(payload) {
  const data = await readData();
  data.analytics.unshift({ ...payload, _at: new Date().toISOString() });
  data.analytics.splice(MAX_ANALYTICS);
  await writeData(data);
}

async function appendFeedback(payload) {
  const data = await readData();
  data.feedback.unshift({ ...payload, _at: new Date().toISOString() });
  data.feedback.splice(MAX_FEEDBACK);
  await writeData(data);
}

module.exports = { readData, appendAnalytics, appendFeedback };
