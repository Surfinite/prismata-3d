const express = require('express');
const router = express.Router();

router.get('/status', (req, res) => {
  res.json({ state: 'browse', session: null, gpu: null, message: 'GPU offline — browse models below' });
});

module.exports = router;
