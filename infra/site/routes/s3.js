const express = require('express');
const { s3, BUCKET } = require('../lib/s3client');
const {
  ListObjectsV2Command, GetObjectCommand, PutObjectCommand,
  DeleteObjectCommand, HeadObjectCommand
} = require('@aws-sdk/client-s3');
const { getSignedUrl } = require('@aws-sdk/s3-request-presigner');

const router = express.Router();

// GET /api/s3/check/:unit/:skin
router.get('/check/:unit/:skin', async (req, res) => {
  const { unit, skin } = req.params;
  try {
    const prefix = `models/${unit}/${skin}/`;
    const resp = await s3.send(new ListObjectsV2Command({ Bucket: BUCKET, Prefix: prefix }));
    if (!resp.KeyCount) return res.json({ exists: false });

    const files = [];
    let meta = null;
    for (const obj of resp.Contents || []) {
      const name = obj.Key.split('/').pop();
      if (name.endsWith('.meta.json')) {
        try {
          const m = await s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: obj.Key }));
          meta = JSON.parse(await m.Body.transformToString());
        } catch {}
      } else if (name.startsWith('latest.')) {
        continue;
      } else if (!name.endsWith('.json')) {
        files.push({
          key: obj.Key, name, size: obj.Size,
          modified: obj.LastModified.toISOString()
        });
      }
    }
    files.sort((a, b) => b.modified.localeCompare(a.modified));
    res.json({ exists: true, files, meta });
  } catch (e) {
    res.json({ exists: false, error: e.message });
  }
});

// GET /api/s3/model-url/:unit/:skin — presigned URL (HeadObject first)
router.get('/model-url/:unit/:skin', async (req, res) => {
  const { unit, skin } = req.params;
  const fmt = req.query.format || 'glb';
  const filename = req.query.filename || '';
  try {
    let key;
    if (filename && !filename.includes('..') && !filename.includes('/')) {
      key = `models/${unit}/${skin}/${filename}`;
    } else {
      key = `models/${unit}/${skin}/latest.${fmt}`;
    }
    await s3.send(new HeadObjectCommand({ Bucket: BUCKET, Key: key }));
    const url = await getSignedUrl(s3, new GetObjectCommand({ Bucket: BUCKET, Key: key }), {
      expiresIn: 3600
    });
    res.json({ url, key, filename: filename || `latest.${fmt}` });
  } catch (e) {
    if (e.name === 'NotFound' || e.$metadata?.httpStatusCode === 404) {
      return res.status(404).json({ error: 'Model not found' });
    }
    res.status(500).json({ error: e.message });
  }
});

// GET /api/s3/list
router.get('/list', async (req, res) => {
  try {
    const resp = await s3.send(new ListObjectsV2Command({
      Bucket: BUCKET, Prefix: 'models/', Delimiter: '/'
    }));
    const units = {};
    for (const prefix of resp.CommonPrefixes || []) {
      const unit = prefix.Prefix.split('/')[1];
      const skinResp = await s3.send(new ListObjectsV2Command({
        Bucket: BUCKET, Prefix: `models/${unit}/`, Delimiter: '/'
      }));
      const skins = (skinResp.CommonPrefixes || []).map(p => p.Prefix.split('/')[2]);
      if (skins.length) units[unit] = skins;
    }
    res.json(units);
  } catch (e) {
    res.json({ error: e.message });
  }
});

// GET /api/s3/favorites
router.get('/favorites', async (req, res) => {
  try {
    const resp = await s3.send(new ListObjectsV2Command({
      Bucket: BUCKET, Prefix: 'favorites/'
    }));
    const favs = [];
    for (const obj of resp.Contents || []) {
      if (obj.Key.endsWith('.fav.json')) {
        try {
          const m = await s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: obj.Key }));
          favs.push(JSON.parse(await m.Body.transformToString()));
        } catch {}
      }
    }
    res.json(favs);
  } catch {
    res.json([]);
  }
});

// POST /api/s3/favorite
router.post('/favorite', async (req, res) => {
  const { unit, skin, filename, params } = req.body;
  if (!unit || !skin || !filename) return res.status(400).json({ error: 'Missing fields' });
  try {
    const fav = {
      unit, skin, filename, params,
      favorited_at: new Date().toISOString()
    };
    await s3.send(new PutObjectCommand({
      Bucket: BUCKET,
      Key: `favorites/${unit}/${skin}/${filename}.fav.json`,
      Body: JSON.stringify(fav, null, 2),
      ContentType: 'application/json'
    }));
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// POST /api/s3/unfavorite
router.post('/unfavorite', async (req, res) => {
  const { unit, skin, filename } = req.body;
  if (!unit || !skin || !filename) return res.status(400).json({ error: 'Missing fields' });
  try {
    await s3.send(new DeleteObjectCommand({
      Bucket: BUCKET,
      Key: `favorites/${unit}/${skin}/${filename}.fav.json`
    }));
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// POST /api/s3/reject
router.post('/reject', async (req, res) => {
  const { unit, skin, filename, params } = req.body;
  if (!unit || !skin || !filename) return res.status(400).json({ error: 'Missing fields' });
  try {
    const rej = {
      unit, skin, filename, params,
      rejected_at: new Date().toISOString()
    };
    await s3.send(new PutObjectCommand({
      Bucket: BUCKET,
      Key: `rejections/${unit}/${skin}/${filename}.rej.json`,
      Body: JSON.stringify(rej, null, 2),
      ContentType: 'application/json'
    }));
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

module.exports = router;
