'use strict';

const express = require('express');
const { validatePayload } = require('./validate');

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '1mb' }));

// Track request count within this single long-lived execution environment
let envRequestsServed = 0;
let activeInFlight = 0;
let peakInFlightObserved = 0;

app.get('/health', (_req, res) => {
  res.json({
    status: 'ok',
    uptimeSec: Number(process.uptime().toFixed(2)),
    arch: process.arch,
    node: process.version,
    initType: process.env.AWS_LAMBDA_INITIALIZATION_TYPE || 'local'
  });
});

app.post('/validate', async (req, res) => {
  envRequestsServed += 1;
  activeInFlight += 1;
  if (activeInFlight > peakInFlightObserved) {
    peakInFlightObserved = activeInFlight;
  }

  try {
    // Optional artificial async I/O wait (e.g. simulating a DB/API call) to observe
    // multi-request concurrency inside a single Web Function environment vs 1-per-env Event Lambda
    const simulateIoMs = Math.min(Math.max(Number(req.query.ioMs) || 0, 0), 500);
    if (simulateIoMs > 0) {
      await new Promise((resolve) => setTimeout(resolve, simulateIoMs));
    }

    const result = validatePayload(req.body);
    res.status(result.statusCode).json({
      ...result.body,
      meta: {
        pattern: 'lambda-web-function',
        arch: process.arch,
        envRequestsServed,
        peakInFlightObserved,
        authHeaderPresent: Boolean(req.headers.authorization)
      }
    });
  } finally {
    activeInFlight -= 1;
  }
});

const [host, port] = (
  process.env.AWS_LAMBDA_HTTP_ENDPOINT || '127.0.0.1:3000'
).split(':');

app.listen(Number(port), host, () => {
  console.log(`Web Function listening on ${host}:${port}`);
});
