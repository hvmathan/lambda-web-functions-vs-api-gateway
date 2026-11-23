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

  const simulateIoMs = Math.min(
    Math.max(Number(event.queryStringParameters?.ioMs) || 0, 0),
    500
  );
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
