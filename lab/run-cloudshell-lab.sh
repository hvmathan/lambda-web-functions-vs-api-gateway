#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# CB Speed Run 2 - Turnkey CloudShell Experiment Runner
# Deploys Path A (API Gateway HTTP API + Event Lambda) and Path B (Lambda Web Function),
# verifies IAM SigV4 auth & edge cases, runs latency/concurrency benchmarks,
# fetches sanitized CloudWatch init/report records, and prepares 1-command cleanup.
# ==============================================================================

export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_PAGER=""
WORKDIR="$HOME/cb-speedrun-lab"

echo ">>> [1/7] Checking AWS CLI for lambda-web support in region $AWS_REGION..."
if ! aws lambda-web help >/dev/null 2>&1; then
  echo "    Updating AWS CLI v2 in CloudShell to get 'aws lambda-web'..."
  ARCH="$(uname -m)"
  TMP_CLI="$(mktemp -d)"
  curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" -o "$TMP_CLI/awscliv2.zip"
  unzip -q "$TMP_CLI/awscliv2.zip" -d "$TMP_CLI"
  sudo "$TMP_CLI/aws/install" --update
  rm -rf "$TMP_CLI"
  hash -r
fi

echo "    AWS CLI version: $(aws --version)"
echo "    Node.js version: $(node --version)"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET_NAME="cb-speedrun-artifacts-${ACCOUNT_ID}-${AWS_REGION}"
STACK_NAME="cb-speedrun-apigw-stack"
WEBFN_NAME="cb-speedrun-web-fn"

mkdir -p "$WORKDIR/web-fn" "$WORKDIR/apigw-fn"
cd "$WORKDIR"

echo ">>> [2/7] Writing shared validation logic, Path A handler, and Path B Express server..."

cat <<'EOF' > "$WORKDIR/validate.js"
'use strict';

function validatePayload(payload) {
  const rows = payload?.rows;
  if (!Array.isArray(rows)) {
    return { statusCode: 400, body: { error: 'rows must be an array' } };
  }
  const invalidRows = [];
  for (let i = 0; i < rows.length; i++) {
    const row = rows[i];
    const validId = typeof row?.id === 'string' && row.id.trim().length > 0;
    const validAmount =
      typeof row?.amount === 'number' && Number.isFinite(row.amount) && row.amount > 0;
    if (!validId || !validAmount) invalidRows.push(i + 1);
  }
  return {
    statusCode: 200,
    body: { rowCount: rows.length, invalidCount: invalidRows.length, invalidRows }
  };
}

module.exports = { validatePayload };
EOF

cp "$WORKDIR/validate.js" "$WORKDIR/web-fn/validate.js"
cp "$WORKDIR/validate.js" "$WORKDIR/apigw-fn/validate.js"

cat <<'EOF' > "$WORKDIR/web-fn/package.json"
{
  "name": "cb-speedrun-web-fn",
  "version": "1.0.0",
  "private": true,
  "main": "index.js",
  "dependencies": {
    "express": "^4.21.2"
  }
}
EOF

cat <<'EOF' > "$WORKDIR/web-fn/index.js"
'use strict';

const express = require('express');
const { validatePayload } = require('./validate');

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '1mb' }));

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
  if (activeInFlight > peakInFlightObserved) peakInFlightObserved = activeInFlight;

  try {
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

const [host, port] = (process.env.AWS_LAMBDA_HTTP_ENDPOINT || '127.0.0.1:3000').split(':');
app.listen(Number(port), host, () => {
  console.log(`Web Function listening on ${host}:${port}`);
});
EOF

cat <<'EOF' > "$WORKDIR/apigw-fn/index.js"
'use strict';

const { validatePayload } = require('./validate');
let envInvocations = 0;

exports.handler = async (event) => {
  envInvocations += 1;
  let parsedBody = {};
  if (event.body) {
    try {
      const raw = event.isBase64Encoded
        ? Buffer.from(event.body, 'base64').toString('utf8')
        : event.body;
      parsedBody = JSON.parse(raw);
    } catch {
      return {
        statusCode: 400,
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ error: 'Invalid JSON body' })
      };
    }
  }
  const simulateIoMs = Math.min(Math.max(Number(event.queryStringParameters?.ioMs) || 0, 0), 500);
  if (simulateIoMs > 0) {
    await new Promise((resolve) => setTimeout(resolve, simulateIoMs));
  }
  const result = validatePayload(parsedBody);
  return {
    statusCode: result.statusCode,
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      ...result.body,
      meta: {
        pattern: 'apigw-event-lambda',
        arch: process.arch,
        envInvocations,
        iamCallerPresent: Boolean(event.requestContext?.authorizer?.iam)
      }
    })
  };
};
EOF

echo ">>> [3/7] Installing Express in web-fn and deploying Lambda Web Function (Path B)..."
(cd "$WORKDIR/web-fn" && npm install --omit=dev --no-audit --no-fund --silent)

DEPLOY_START_EPOCH=$(date +%s)
aws lambda-web deploy \
  --name "$WEBFN_NAME" \
  --code "$WORKDIR/web-fn" \
  --create \
  --auth-type IamAuth \
  --env NODE_ENV=production \
  --region "$AWS_REGION" \
  --output json > "$WORKDIR/webfn-deploy.json"
DEPLOY_END_EPOCH=$(date +%s)
WEBFN_DEPLOY_SECONDS=$((DEPLOY_END_EPOCH - DEPLOY_START_EPOCH))

WEBFN_HOST="$(node -e "console.log(require('$WORKDIR/webfn-deploy.json').endpointUrl)")"
WEBFN_CLI_BUCKET="$(node -e "console.log(require('$WORKDIR/webfn-deploy.json').bucketName || '')")"
WEBFN_CLI_ROLE_ARN="$(node -e "console.log(require('$WORKDIR/webfn-deploy.json').roleArn || '')")"
echo "    Web Function deployed in ${WEBFN_DEPLOY_SECONDS}s."

# Read actual runtime used by Web Function so Path A uses the exact same Node.js runtime!
WEBFN_RUNTIME="$(aws lambda-web list-web-function-revisions --function-name "$WEBFN_NAME" --region "$AWS_REGION" --query 'revisions[0].runtime' --output text 2>/dev/null || echo 'nodejs22.x')"
if [[ "$WEBFN_RUNTIME" == "None" || -z "$WEBFN_RUNTIME" ]]; then
  REV_ID="$(node -e "console.log(require('$WORKDIR/webfn-deploy.json').revisionId || '')")"
  if [[ -n "$REV_ID" ]]; then
    WEBFN_RUNTIME="$(aws lambda-web get-web-function-revision --function-name "$WEBFN_NAME" --revision-id "$REV_ID" --region "$AWS_REGION" --query 'buildConfig.runtimeConfig.runtime' --output text 2>/dev/null || echo 'nodejs22.x')"
  else
    WEBFN_RUNTIME="nodejs22.x"
  fi
fi
echo "    Detected Web Function runtime: $WEBFN_RUNTIME"

# Check if Event Lambda supports that exact runtime, fallback to nodejs22.x if needed
EVENT_RUNTIME="$WEBFN_RUNTIME"
if [[ "$EVENT_RUNTIME" != nodejs* ]]; then
  EVENT_RUNTIME="nodejs22.x"
fi

echo ">>> [4/7] Packaging & deploying API Gateway HTTP API + Event Lambda (Path A)..."
if ! aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" >/dev/null
  else
    aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" \
      --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null
  fi
fi

(cd "$WORKDIR/apigw-fn" && zip -qr "$WORKDIR/apigw-fn.zip" index.js validate.js)
aws s3 cp "$WORKDIR/apigw-fn.zip" "s3://$BUCKET_NAME/apigw-fn.zip" --region "$AWS_REGION" >/dev/null

cat <<'EOF' > "$WORKDIR/apigw-template.yaml"
AWSTemplateFormatVersion: '2010-09-09'
Description: Path A baseline - API Gateway HTTP API + Arm64 Node.js Lambda Event Function
Parameters:
  CodeBucket:
    Type: String
  CodeKey:
    Type: String
  RuntimeName:
    Type: String
Resources:
  ValidateFunctionRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal: { Service: lambda.amazonaws.com }
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  ValidateFunction:
    Type: AWS::Lambda::Function
    Properties:
      FunctionName: cb-speedrun-apigw-fn
      Runtime: !Ref RuntimeName
      Architectures: [arm64]
      Handler: index.handler
      MemorySize: 512
      Timeout: 30
      Role: !GetAtt ValidateFunctionRole.Arn
      Code:
        S3Bucket: !Ref CodeBucket
        S3Key: !Ref CodeKey
  HttpApi:
    Type: AWS::ApiGatewayV2::Api
    Properties:
      Name: cb-speedrun-http-api
      ProtocolType: HTTP
  LambdaIntegration:
    Type: AWS::ApiGatewayV2::Integration
    Properties:
      ApiId: !Ref HttpApi
      IntegrationType: AWS_PROXY
      IntegrationUri: !GetAtt ValidateFunction.Arn
      PayloadFormatVersion: '2.0'
  ValidateRoute:
    Type: AWS::ApiGatewayV2::Route
    Properties:
      ApiId: !Ref HttpApi
      RouteKey: POST /validate
      AuthorizationType: AWS_IAM
      Target: !Sub integrations/${LambdaIntegration}
  DefaultStage:
    Type: AWS::ApiGatewayV2::Stage
    Properties:
      ApiId: !Ref HttpApi
      StageName: $default
      AutoDeploy: true
  AllowApiGatewayInvoke:
    Type: AWS::Lambda::Permission
    Properties:
      FunctionName: !Ref ValidateFunction
      Action: lambda:InvokeFunction
      Principal: apigateway.amazonaws.com
      SourceArn: !Sub arn:aws:execute-api:${AWS::Region}:${AWS::AccountId}:${HttpApi}/*/*/validate
Outputs:
  ApiEndpoint:
    Value: !GetAtt HttpApi.ApiEndpoint
EOF

CFN_START_EPOCH=$(date +%s)
if ! aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$WORKDIR/apigw-template.yaml" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides CodeBucket="$BUCKET_NAME" CodeKey="apigw-fn.zip" RuntimeName="$EVENT_RUNTIME" \
  --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "    Retrying CloudFormation with nodejs22.x fallback..."
  EVENT_RUNTIME="nodejs22.x"
  aws cloudformation deploy \
    --stack-name "$STACK_NAME" \
    --template-file "$WORKDIR/apigw-template.yaml" \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides CodeBucket="$BUCKET_NAME" CodeKey="apigw-fn.zip" RuntimeName="$EVENT_RUNTIME" \
    --region "$AWS_REGION" >/dev/null
fi
CFN_END_EPOCH=$(date +%s)
APIGW_DEPLOY_SECONDS=$((CFN_END_EPOCH - CFN_START_EPOCH))

APIGW_URL="$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='ApiEndpoint'].OutputValue" --output text)"
echo "    API Gateway + Event Lambda deployed in ${APIGW_DEPLOY_SECONDS}s."

echo ">>> [5/7] Running SigV4 auth checks, cold hit, sequential & concurrent benchmarks..."

cat <<'EOF' > "$WORKDIR/benchmark.js"
'use strict';
const crypto = require('crypto');
const https = require('https');
const { execSync } = require('child_process');
const { performance } = require('perf_hooks');

const agent = new https.Agent({ keepAlive: true, maxSockets: 64 });
const sha256Hex = (d) => crypto.createHash('sha256').update(d, 'utf8').digest('hex');
const hmac = (k, d, enc) => crypto.createHmac('sha256', k).update(d, 'utf8').digest(enc);

function getSigningKey(secret, dateStamp, region, service) {
  return hmac(hmac(hmac(hmac('AWS4' + secret, dateStamp), region), service), 'aws4_request');
}

function loadAwsCredentials() {
  if (process.env.AWS_ACCESS_KEY_ID && process.env.AWS_SECRET_ACCESS_KEY) {
    return {
      accessKeyId: process.env.AWS_ACCESS_KEY_ID,
      secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY,
      sessionToken: process.env.AWS_SESSION_TOKEN || ''
    };
  }
  const parsed = JSON.parse(execSync('aws configure export-credentials --format process', { encoding: 'utf8' }));
  return {
    accessKeyId: parsed.AccessKeyId,
    secretAccessKey: parsed.SecretAccessKey,
    sessionToken: parsed.SessionToken || ''
  };
}

function signSigV4({ method, urlObj, body, service, region, creds, includeContentSha256Header }) {
  const amzDate = new Date().toISOString().replace(/[:-]|\.\d{3}/g, '');
  const dateStamp = amzDate.slice(0, 8);
  const payloadHash = sha256Hex(body);
  const headers = {
    'content-type': 'application/json',
    host: urlObj.host,
    'x-amz-date': amzDate
  };
  if (includeContentSha256Header) headers['x-amz-content-sha256'] = payloadHash;
  if (creds.sessionToken) headers['x-amz-security-token'] = creds.sessionToken;

  const sortedKeys = Object.keys(headers).sort();
  const canonicalHeaders = sortedKeys.map((k) => `${k}:${headers[k]}\n`).join('');
  const signedHeaders = sortedKeys.join(';');
  const params = [...urlObj.searchParams.entries()].map(([k, v]) => [encodeURIComponent(k), encodeURIComponent(v)]);
  params.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
  const canonicalQuery = params.map(([k, v]) => `${k}=${v}`).join('&');

  const canonicalRequest = [method, urlObj.pathname || '/', canonicalQuery, canonicalHeaders, signedHeaders, payloadHash].join('\n');
  const scope = `${dateStamp}/${region}/${service}/aws4_request`;
  const stringToSign = ['AWS4-HMAC-SHA256', amzDate, scope, sha256Hex(canonicalRequest)].join('\n');
  const signature = hmac(getSigningKey(creds.secretAccessKey, dateStamp, region, service), stringToSign, 'hex');

  headers.Authorization = `AWS4-HMAC-SHA256 Credential=${creds.accessKeyId}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`;
  headers['content-length'] = Buffer.byteLength(body);
  return headers;
}

function sendHttp({ method, urlStr, body, headers }) {
  const urlObj = new URL(urlStr);
  const start = performance.now();
  return new Promise((resolve) => {
    const req = https.request(
      { protocol: urlObj.protocol, hostname: urlObj.hostname, port: 443, path: urlObj.pathname + urlObj.search, method, headers, agent },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          const latencyMs = performance.now() - start;
          const rawBody = Buffer.concat(chunks).toString('utf8');
          let json = null;
          try { json = JSON.parse(rawBody); } catch {}
          resolve({ statusCode: res.statusCode, latencyMs, httpVersion: res.httpVersion, headers: res.headers, rawBody, json });
        });
      }
    );
    req.on('error', (err) => resolve({ statusCode: 0, latencyMs: performance.now() - start, error: err.message }));
    if (body) req.write(body);
    req.end();
  });
}

function percentile(sorted, p) {
  if (!sorted.length) return 0;
  return Number(sorted[Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1)].toFixed(2));
}

function summarize(results) {
  const ok = results.filter((r) => r.statusCode === 200);
  const sorted = ok.map((r) => r.latencyMs).sort((a, b) => a - b);
  const sum = sorted.reduce((a, b) => a + b, 0);
  const statusCounts = {};
  for (const r of results) statusCounts[r.statusCode] = (statusCounts[r.statusCode] || 0) + 1;
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
    peakInFlightInSingleEnv: ok.reduce((m, r) => Math.max(m, r.json?.meta?.peakInFlightObserved || 1), 1),
    maxRequestsHandledByOneEnv: ok.reduce((m, r) => Math.max(m, r.json?.meta?.envRequestsServed || r.json?.meta?.envInvocations || 0), 0)
  };
}

async function runPool(total, concurrency, fn) {
  const results = new Array(total);
  let i = 0;
  await Promise.all(Array.from({ length: concurrency }, async () => {
    while (true) {
      const idx = i++;
      if (idx >= total) break;
      results[idx] = await fn(idx);
    }
  }));
  return results;
}

(async () => {
  const region = process.env.AWS_REGION || 'us-east-1';
  const apigwUrl = `${process.env.APIGW_URL.replace(/\/$/, '')}/validate`;
  const webFnUrl = `https://${process.env.WEBFN_HOST.replace(/^https?:\/\//, '').replace(/\/$/, '')}/validate`;
  const creds = loadAwsCredentials();
  const payload = JSON.stringify({
    rows: [
      { id: 'A-101', amount: 125.5 },
      { id: 'A-102', amount: 40 },
      { id: '', amount: 0 },
      { id: 'A-104', amount: -15 },
      { id: 'A-105', amount: 89.99 }
    ]
  });

  const call = (target, q = '', opts = {}) => {
    const fullUrl = (target === 'webfn' ? webFnUrl : apigwUrl) + (q ? `?${q}` : '');
    if (opts.unsigned) {
      return sendHttp({ method: 'POST', urlStr: fullUrl, body: payload, headers: { 'content-type': 'application/json', 'content-length': Buffer.byteLength(payload) } });
    }
    const headers = signSigV4({
      method: 'POST',
      urlObj: new URL(fullUrl),
      body: payload,
      service: target === 'webfn' ? 'lambda' : 'execute-api',
      region,
      creds,
      includeContentSha256Header: opts.omitSha256 ? false : target === 'webfn'
    });
    return sendHttp({ method: 'POST', urlStr: fullUrl, body: payload, headers });
  };

  const unsignedApigw = await call('apigw', '', { unsigned: true });
  const unsignedWebFn = await call('webfn', '', { unsigned: true });
  const webFnMissingSha = await call('webfn', '', { omitSha256: true });

  const firstApigw = await call('apigw');
  const firstWebFn = await call('webfn');

  await runPool(20, 4, () => call('apigw'));
  await runPool(20, 4, () => call('webfn'));

  const seqApigw = await runPool(100, 1, () => call('apigw'));
  const seqWebFn = await runPool(100, 1, () => call('webfn'));

  const concApigw = await runPool(200, 20, () => call('apigw'));
  const concWebFn = await runPool(200, 20, () => call('webfn'));

  // Run a second wave after 3 seconds so Web Function dynamic concurrency learning settles
  await new Promise((r) => setTimeout(r, 3000));
  const ioApigw = await runPool(120, 20, () => call('apigw', 'ioMs=75'));
  const ioWebFn = await runPool(120, 20, () => call('webfn', 'ioMs=75'));

  console.log(JSON.stringify({
    timestampUtc: new Date().toISOString(),
    region,
    clientNodeVersion: process.version,
    deployMeta: {
      webFnRuntime: process.env.WEBFN_RUNTIME,
      eventRuntime: process.env.EVENT_RUNTIME,
      webFnDeploySeconds: Number(process.env.WEBFN_DEPLOY_SECONDS),
      apigwDeploySeconds: Number(process.env.APIGW_DEPLOY_SECONDS)
    },
    authChecks: {
      apigwUnsignedStatus: unsignedApigw.statusCode,
      webFnUnsignedStatus: unsignedWebFn.statusCode,
      webFnSignedWithoutContentSha256Status: webFnMissingSha.statusCode
    },
    firstSignedRequest: {
      apigw: { statusCode: firstApigw.statusCode, latencyMs: Number(firstApigw.latencyMs.toFixed(2)), httpVersion: firstApigw.httpVersion, contentEncoding: firstApigw.headers?.['content-encoding'] || 'none', body: firstApigw.json },
      webFn: { statusCode: firstWebFn.statusCode, latencyMs: Number(firstWebFn.latencyMs.toFixed(2)), httpVersion: firstWebFn.httpVersion, hasLambdaWebRequestIdHeader: Boolean(firstWebFn.headers?.['lambda-web-request-id']), contentEncoding: firstWebFn.headers?.['content-encoding'] || 'none', body: firstWebFn.json }
    },
    warmSequential100: { apigw: summarize(seqApigw), webFn: summarize(seqWebFn) },
    concurrentBurst200_c20: { apigw: summarize(concApigw), webFn: summarize(concWebFn) },
    concurrentIoWait120_c20_75ms: { apigw: summarize(ioApigw), webFn: summarize(ioWebFn) }
  }, null, 2));
})();
EOF

APIGW_URL="$APIGW_URL" \
WEBFN_HOST="$WEBFN_HOST" \
WEBFN_RUNTIME="$WEBFN_RUNTIME" \
EVENT_RUNTIME="$EVENT_RUNTIME" \
WEBFN_DEPLOY_SECONDS="$WEBFN_DEPLOY_SECONDS" \
APIGW_DEPLOY_SECONDS="$APIGW_DEPLOY_SECONDS" \
node "$WORKDIR/benchmark.js" > "$WORKDIR/benchmark-results.json"

echo ">>> [6/7] Waiting 12s for CloudWatch Logs to flush, then sampling platform & REPORT lines..."
sleep 12

WEBFN_LOG_GROUP="/aws/lambda/web/${WEBFN_NAME}"
APIGW_LOG_GROUP="/aws/lambda/cb-speedrun-apigw-fn"

WEBFN_LOG_SAMPLE="$(aws logs filter-log-events \
  --log-group-name "$WEBFN_LOG_GROUP" \
  --region "$AWS_REGION" \
  --limit 25 \
  --query 'events[].message' --output json 2>/dev/null || echo '[]')"

APIGW_LOG_SAMPLE="$(aws logs filter-log-events \
  --log-group-name "$APIGW_LOG_GROUP" \
  --filter-pattern "REPORT" \
  --region "$AWS_REGION" \
  --limit 10 \
  --query 'events[].message' --output json 2>/dev/null || echo '[]')"

APIGW_STREAM_COUNT="$(aws logs describe-log-streams \
  --log-group-name "$APIGW_LOG_GROUP" \
  --region "$AWS_REGION" \
  --query 'length(logStreams)' --output text 2>/dev/null || echo 'unknown')"

WEBFN_STREAM_COUNT="$(aws logs describe-log-streams \
  --log-group-name "$WEBFN_LOG_GROUP" \
  --region "$AWS_REGION" \
  --query 'length(logStreams)' --output text 2>/dev/null || echo 'unknown')"

echo ">>> [7/7] Generating cleanup.sh so you can tear down everything in 1 command..."
WEBFN_CLI_ROLE_NAME="${WEBFN_CLI_ROLE_ARN##*/}"
cat <<EOF > "$WORKDIR/cleanup.sh"
#!/usr/bin/env bash
set -uo pipefail
export AWS_REGION="$AWS_REGION"
export AWS_PAGER=""

echo "Deleting Lambda Web Function ($WEBFN_NAME)..."
ENDPOINTS=\$(aws lambda-web list-web-function-endpoints --function-name "$WEBFN_NAME" --region "$AWS_REGION" --query 'endpoints[].endpointName' --output text 2>/dev/null || true)
for EP in \$ENDPOINTS; do
  aws lambda-web delete-web-function-endpoint --function-name "$WEBFN_NAME" --endpoint-name "\$EP" --region "$AWS_REGION" || true
done
sleep 5
aws lambda-web delete-web-function --function-name "$WEBFN_NAME" --region "$AWS_REGION" || true

ROLE_NAME="$WEBFN_CLI_ROLE_NAME"
if [[ -n "\$ROLE_NAME" ]]; then
  echo "Cleaning CLI-created role \$ROLE_NAME..."
  POLICIES=\$(aws iam list-attached-role-policies --role-name "\$ROLE_NAME" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true)
  for P in \$POLICIES; do aws iam detach-role-policy --role-name "\$ROLE_NAME" --policy-arn "\$P" || true; done
  INLINE=\$(aws iam list-role-policies --role-name "\$ROLE_NAME" --query 'PolicyNames[]' --output text 2>/dev/null || true)
  for IP in \$INLINE; do aws iam delete-role-policy --role-name "\$ROLE_NAME" --policy-name "\$IP" || true; done
  aws iam delete-role --role-name "\$ROLE_NAME" || true
fi

echo "Deleting CloudFormation stack ($STACK_NAME)..."
aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$AWS_REGION" || true
aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$AWS_REGION" || true

echo "Emptying & deleting S3 artifact bucket ($BUCKET_NAME)..."
aws s3 rb "s3://$BUCKET_NAME" --force --region "$AWS_REGION" || true

echo "Deleting CloudWatch log groups..."
aws logs delete-log-group --log-group-name "$WEBFN_LOG_GROUP" --region "$AWS_REGION" || true
aws logs delete-log-group --log-group-name "${WEBFN_LOG_GROUP}.local" --region "$AWS_REGION" || true
aws logs delete-log-group --log-group-name "$APIGW_LOG_GROUP" --region "$AWS_REGION" || true

echo "Note: Shared CLI bucket '$WEBFN_CLI_BUCKET' (if created by aws lambda-web deploy) was left intact or can be emptied manually if unused."
echo "All test endpoints, functions, stack, and log groups deleted!"
EOF
chmod +x "$WORKDIR/cleanup.sh"

echo ""
echo "================================================================================"
echo " COPY EVERYTHING BETWEEN THE MARKERS BELOW AND PASTE IT BACK INTO COPILOT CHAT"
echo " (Your AWS Account ID and live endpoint IDs have been automatically masked)"
echo "================================================================================"
echo "=== LAB_EVIDENCE_START ==="
ACCOUNT_ID="$ACCOUNT_ID" \
WEBFN_HOST="$WEBFN_HOST" \
APIGW_URL="$APIGW_URL" \
APIGW_STREAM_COUNT="$APIGW_STREAM_COUNT" \
WEBFN_STREAM_COUNT="$WEBFN_STREAM_COUNT" \
WEBFN_LOG_SAMPLE="$WEBFN_LOG_SAMPLE" \
APIGW_LOG_SAMPLE="$APIGW_LOG_SAMPLE" \
AWS_CLI_VER="$(aws --version 2>&1)" \
node -e '
const fs = require("fs");
const acct = process.env.ACCOUNT_ID;
const webHost = process.env.WEBFN_HOST;
const apigwUrl = process.env.APIGW_URL;

function mask(str) {
  if (!str) return str;
  let s = String(str);
  if (acct) s = s.split(acct).join("<ACCOUNT_ID>");
  if (webHost) {
    const parts = webHost.split(".");
    if (parts.length >= 2) {
      s = s.split(parts[0]).join("<ENDPOINT_ID>").split(parts[1]).join("<SHARD>");
    }
  }
  const m = apigwUrl && apigwUrl.match(/https:\/\/([a-z0-9]+)\.execute-api/);
  if (m && m[1]) s = s.split(m[1]).join("<API_ID>");
  return s;
}

const bench = JSON.parse(fs.readFileSync("benchmark-results.json", "utf8"));
const deployInfo = JSON.parse(fs.readFileSync("webfn-deploy.json", "utf8"));
const webLogs = JSON.parse(process.env.WEBFN_LOG_SAMPLE || "[]").slice(0, 12);
const apigwLogs = JSON.parse(process.env.APIGW_LOG_SAMPLE || "[]").slice(0, 5);

const out = {
  cliVersion: process.env.AWS_CLI_VER,
  sanitizedEndpoints: {
    webFunctionDomainPattern: mask(webHost),
    apiGatewayUrlPattern: mask(apigwUrl)
  },
  sanitizedWebFnDeployOutput: JSON.parse(mask(JSON.stringify(deployInfo))),
  benchmark: bench,
  cloudWatchSummary: {
    apigwLogStreamCount: process.env.APIGW_STREAM_COUNT,
    webFnLogStreamCount: process.env.WEBFN_STREAM_COUNT,
    sampleApigwReports: apigwLogs.map(mask),
    sampleWebFnEvents: webLogs.map(mask)
  }
};
console.log(JSON.stringify(out, null, 2));
'
echo "=== LAB_EVIDENCE_END ==="
echo ""
echo ">>> When you have copied the block above, tear everything down immediately by running:"
echo "    ~/cb-speedrun-lab/cleanup.sh"
