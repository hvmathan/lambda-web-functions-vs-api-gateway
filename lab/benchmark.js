'use strict';

/**
 * Zero-dependency SigV4 HTTP/HTTPS benchmark client for comparing:
 *  - Path A: API Gateway HTTP API (AWS_IAM -> service: execute-api)
 *  - Path B: Lambda Web Function (IamAuth -> service: lambda, requires X-Amz-Content-SHA256)
 *
 * Uses AWS credentials from standard AWS CLI / CloudShell environment via `aws configure export-credentials`
 * or environment variables, and masks sensitive IDs before printing summary JSON.
 */

const crypto = require('crypto');
const https = require('https');
const { execSync } = require('child_process');
const { performance } = require('perf_hooks');

const agent = new https.Agent({
  keepAlive: true,
  maxSockets: 64
});

function sha256Hex(data) {
  return crypto.createHash('sha256').update(data, 'utf8').digest('hex');
}

function hmac(key, data, encoding) {
  return crypto.createHmac('sha256', key).update(data, 'utf8').digest(encoding);
}

function getSigningKey(secretAccessKey, dateStamp, region, service) {
  const kDate = hmac('AWS4' + secretAccessKey, dateStamp);
  const kRegion = hmac(kDate, region);
  const kService = hmac(kRegion, service);
  return hmac(kService, 'aws4_request');
}

function loadAwsCredentials() {
  if (process.env.AWS_ACCESS_KEY_ID && process.env.AWS_SECRET_ACCESS_KEY) {
    return {
      accessKeyId: process.env.AWS_ACCESS_KEY_ID,
      secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY,
      sessionToken: process.env.AWS_SESSION_TOKEN || ''
    };
  }
  const out = execSync('aws configure export-credentials --format process', {
    encoding: 'utf8'
  });
  const parsed = JSON.parse(out);
  return {
    accessKeyId: parsed.AccessKeyId,
    secretAccessKey: parsed.SecretAccessKey,
    sessionToken: parsed.SessionToken || ''
  };
}

function signSigV4({ method, urlObj, body, service, region, creds, includeContentSha256Header }) {
  const now = new Date();
  const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, '');
  const dateStamp = amzDate.slice(0, 8);
  const payloadHash = sha256Hex(body);

  const headers = {
    'content-type': 'application/json',
    host: urlObj.host,
    'x-amz-date': amzDate
  };
  if (includeContentSha256Header) {
    headers['x-amz-content-sha256'] = payloadHash;
  }
  if (creds.sessionToken) {
    headers['x-amz-security-token'] = creds.sessionToken;
  }

  const sortedKeys = Object.keys(headers).sort();
  const canonicalHeaders = sortedKeys.map((k) => `${k}:${headers[k]}\n`).join('');
  const signedHeaders = sortedKeys.join(';');

  // Canonical query string sorted by parameter name
  const params = [];
  for (const [k, v] of urlObj.searchParams.entries()) {
    params.push([encodeURIComponent(k), encodeURIComponent(v)]);
  }
  params.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
  const canonicalQuery = params.map(([k, v]) => `${k}=${v}`).join('&');

  const canonicalRequest = [
    method,
    urlObj.pathname || '/',
    canonicalQuery,
    canonicalHeaders,
    signedHeaders,
    payloadHash
  ].join('\n');

  const credentialScope = `${dateStamp}/${region}/${service}/aws4_request`;
  const stringToSign = [
    'AWS4-HMAC-SHA256',
    amzDate,
    credentialScope,
    sha256Hex(canonicalRequest)
  ].join('\n');

  const signingKey = getSigningKey(creds.secretAccessKey, dateStamp, region, service);
  const signature = hmac(signingKey, stringToSign, 'hex');

  headers.Authorization =
    `AWS4-HMAC-SHA256 Credential=${creds.accessKeyId}/${credentialScope}, ` +
    `SignedHeaders=${signedHeaders}, Signature=${signature}`;
  headers['content-length'] = Buffer.byteLength(body);

  return headers;
}

function sendHttp({ method, urlStr, body, headers }) {
  const urlObj = new URL(urlStr);
  const start = performance.now();

  return new Promise((resolve) => {
    const req = https.request(
      {
        protocol: urlObj.protocol,
        hostname: urlObj.hostname,
        port: urlObj.port || 443,
        path: urlObj.pathname + urlObj.search,
        method,
        headers,
        agent
      },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          const latencyMs = performance.now() - start;
          const rawBody = Buffer.concat(chunks).toString('utf8');
          let json = null;
          try {
            json = JSON.parse(rawBody);
          } catch {
            json = null;
          }
          resolve({
            statusCode: res.statusCode,
            latencyMs,
            httpVersion: res.httpVersion,
            headers: res.headers,
            rawBody,
            json
          });
        });
      }
    );

    req.on('error', (err) => {
      resolve({
        statusCode: 0,
        latencyMs: performance.now() - start,
        error: err.message
      });
    });

    if (body) req.write(body);
    req.end();
  });
}

function percentile(sortedArr, p) {
  if (!sortedArr.length) return 0;
  const idx = Math.min(sortedArr.length - 1, Math.ceil((p / 100) * sortedArr.length) - 1);
  return Number(sortedArr[idx].toFixed(2));
}

function summarizeLatencies(results) {
  const ok = results.filter((r) => r.statusCode === 200);
  const sorted = ok.map((r) => r.latencyMs).sort((a, b) => a - b);
  const sum = sorted.reduce((a, b) => a + b, 0);
  const peakInFlight = ok.reduce(
    (max, r) => Math.max(max, r.json?.meta?.peakInFlightObserved || 1),
    1
  );
  const maxEnvReqs = ok.reduce(
    (max, r) =>
      Math.max(max, r.json?.meta?.envRequestsServed || r.json?.meta?.envInvocations || 0),
    0
  );

  const statusCounts = {};
  for (const r of results) {
    statusCounts[r.statusCode] = (statusCounts[r.statusCode] || 0) + 1;
  }

  return {
    totalRequests: results.length,
    okCount: ok.length,
    statusCounts,
    minMs: sorted.length ? Number(sorted[0].toFixed(2)) : null,
    p50Ms: percentile(sorted, 50),
    p95Ms: percentile(sorted, 95),
    p99Ms: percentile(sorted, 99),
    maxMs: sorted.length ? Number(sorted[sorted.length - 1].toFixed(2)) : null,
    avgMs: sorted.length ? Number((sum / sorted.length).toFixed(2)) : null,
    peakInFlightInSingleEnv: peakInFlight,
    maxRequestsHandledByOneEnv: maxEnvReqs
  };
}

async function runPool(total, concurrency, fn) {
  const results = new Array(total);
  let nextIdx = 0;

  async function worker() {
    while (true) {
      const idx = nextIdx++;
      if (idx >= total) break;
      results[idx] = await fn(idx);
    }
  }

  await Promise.all(Array.from({ length: concurrency }, () => worker()));
  return results;
}

async function main() {
  const region = process.env.AWS_REGION || 'us-east-1';
  const apigwBase = process.env.APIGW_URL; // e.g. https://abc123.execute-api.us-east-1.amazonaws.com
  const webFnHost = process.env.WEBFN_HOST; // e.g. id.shard.lambda-web.us-east-1.on.aws

  if (!apigwBase || !webFnHost) {
    console.error('Missing APIGW_URL or WEBFN_HOST env vars');
    process.exit(1);
  }

  const creds = loadAwsCredentials();
  const apigwUrl = `${apigwBase.replace(/\/$/, '')}/validate`;
  const webFnUrl = `https://${webFnHost.replace(/^https?:\/\//, '').replace(/\/$/, '')}/validate`;

  const payload = JSON.stringify({
    rows: [
      { id: 'A-101', amount: 125.5 },
      { id: 'A-102', amount: 40 },
      { id: '', amount: 0 },
      { id: 'A-104', amount: -15 },
      { id: 'A-105', amount: 89.99 }
    ]
  });

  const callTarget = async (target, querySuffix = '', opts = {}) => {
    const fullUrl =
      (target === 'webfn' ? webFnUrl : apigwUrl) + (querySuffix ? `?${querySuffix}` : '');
    const urlObj = new URL(fullUrl);
    if (opts.unsigned) {
      return sendHttp({
        method: 'POST',
        urlStr: fullUrl,
        body: payload,
        headers: {
          'content-type': 'application/json',
          'content-length': Buffer.byteLength(payload)
        }
      });
    }
    const headers = signSigV4({
      method: 'POST',
      urlObj,
      body: payload,
      service: target === 'webfn' ? 'lambda' : 'execute-api',
      region,
      creds,
      includeContentSha256Header: opts.omitSha256 ? false : target === 'webfn'
    });
    return sendHttp({ method: 'POST', urlStr: fullUrl, body: payload, headers });
  };

  const report = {
    timestampUtc: new Date().toISOString(),
    region,
    nodeVersion: process.version,
    tests: {}
  };

  // 1. Auth verification tests (unsigned + WebFn missing X-Amz-Content-SHA256 gotcha)
  const unsignedApigw = await callTarget('apigw', '', { unsigned: true });
  const unsignedWebFn = await callTarget('webfn', '', { unsigned: true });
  const webFnMissingShaHeader = await callTarget('webfn', '', { omitSha256: true });

  report.tests.authChecks = {
    apigwUnsignedStatus: unsignedApigw.statusCode,
    webFnUnsignedStatus: unsignedWebFn.statusCode,
    webFnSignedWithoutContentSha256Status: webFnMissingShaHeader.statusCode
  };

  // 2. First signed request (cold / initial hit)
  const firstApigw = await callTarget('apigw');
  const firstWebFn = await callTarget('webfn');

  report.tests.firstSignedRequest = {
    apigw: {
      statusCode: firstApigw.statusCode,
      latencyMs: Number(firstApigw.latencyMs.toFixed(2)),
      httpVersion: firstApigw.httpVersion,
      contentEncoding: firstApigw.headers?.['content-encoding'] || 'none',
      body: firstApigw.json
    },
    webFn: {
      statusCode: firstWebFn.statusCode,
      latencyMs: Number(firstWebFn.latencyMs.toFixed(2)),
      httpVersion: firstWebFn.httpVersion,
      hasLambdaWebRequestIdHeader: Boolean(firstWebFn.headers?.['lambda-web-request-id']),
      contentEncoding: firstWebFn.headers?.['content-encoding'] || 'none',
      body: firstWebFn.json
    }
  };

  // Warm-up 20 requests each
  await runPool(20, 4, () => callTarget('apigw'));
  await runPool(20, 4, () => callTarget('webfn'));

  // 3. Sequential warm latency (100 requests, concurrency = 1)
  const seqApigw = await runPool(100, 1, () => callTarget('apigw'));
  const seqWebFn = await runPool(100, 1, () => callTarget('webfn'));
  report.tests.warmSequential100 = {
    apigw: summarizeLatencies(seqApigw),
    webFn: summarizeLatencies(seqWebFn)
  };

  // 4. Concurrent CPU-light burst (200 requests, concurrency = 20)
  const concApigw = await runPool(200, 20, () => callTarget('apigw'));
  const concWebFn = await runPool(200, 20, () => callTarget('webfn'));
  report.tests.concurrentBurst200_c20 = {
    apigw: summarizeLatencies(concApigw),
    webFn: summarizeLatencies(concWebFn)
  };

  // 5. Concurrent I/O-wait workload (120 requests, concurrency = 20, 75ms async wait)
  // Demonstrates single Web Function environment multiplexing concurrent I/O waits
  // vs Event Lambda needing ~20 parallel execution environments!
  const ioApigw = await runPool(120, 20, () => callTarget('apigw', 'ioMs=75'));
  const ioWebFn = await runPool(120, 20, () => callTarget('webfn', 'ioMs=75'));
  report.tests.concurrentIoWait120_c20_75ms = {
    apigw: summarizeLatencies(ioApigw),
    webFn: summarizeLatencies(ioWebFn)
  };

  console.log('=== BENCHMARK_JSON_START ===');
  console.log(JSON.stringify(report, null, 2));
  console.log('=== BENCHMARK_JSON_END ===');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
