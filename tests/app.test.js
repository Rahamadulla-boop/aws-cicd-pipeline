const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const app = require('../src/app');

describe('Application Core Endpoints & Safeguards', () => {
  let server;
  let baseUrl;

  before(async () => {
    server = http.createServer(app);
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const address = server.address();
    baseUrl = `http://127.0.0.1:${address.port}`;
  });

  after(async () => {
    await new Promise((resolve) => server.close(resolve));
  });

  test('GET / serves the status dashboard HTML', async () => {
    const res = await fetch(`${baseUrl}/`, {
      headers: { Accept: 'text/html' }
    });
    assert.equal(res.status, 200);
    const contentType = res.headers.get('content-type');
    assert.ok(contentType.includes('text/html'));

    const text = await res.text();
    assert.ok(text.includes('aws-cicd-demo'));
    assert.ok(text.includes('Deployment &amp; Runtime Overview'));
  });

  test('GET /api/ready returns 200 and initialization status', async () => {
    const res = await fetch(`${baseUrl}/api/ready`);
    assert.equal(res.status, 200);

    const body = await res.json();
    assert.equal(body.status, 'ready');
    assert.equal(body.application, process.env.APP_NAME || 'aws-cicd-demo');
    assert.equal(body.checks.initialization, 'passed');
  });

  test('GET /api/info returns deployment metadata without sensitive credentials', async () => {
    const res = await fetch(`${baseUrl}/api/info`);
    assert.equal(res.status, 200);

    const body = await res.json();
    assert.ok(body.application);
    assert.ok(body.version);
    assert.ok(body.environment);
    assert.ok(body.commitSha);
    assert.ok(body.memory);
    assert.ok(typeof body.memory.rssMb === 'number');

    // Security Verification: Ensure no secrets, tokens or aws credentials exist in payload
    const bodyStr = JSON.stringify(body).toLowerCase();
    assert.equal(bodyStr.includes('aws_secret_access_key'), false);
    assert.equal(bodyStr.includes('aws_access_key_id'), false);
    assert.equal(bodyStr.includes('password'), false);
    assert.equal(bodyStr.includes('token'), false);
  });

  test('GET /api/non-existent-route returns 404 with structured JSON message', async () => {
    const res = await fetch(`${baseUrl}/api/non-existent-route`, {
      headers: { Accept: 'application/json' }
    });
    assert.equal(res.status, 404);

    const body = await res.json();
    assert.equal(body.statusCode, 404);
    assert.equal(body.error, 'Not Found');
    assert.ok(body.message.includes('/api/non-existent-route'));
  });

  test('Security response headers are set properly', async () => {
    const res = await fetch(`${baseUrl}/api/health`);
    assert.equal(res.headers.get('x-content-type-options'), 'nosniff');
    assert.equal(res.headers.get('x-frame-options'), 'DENY');
    assert.equal(res.headers.get('x-xss-protection'), '1; mode=block');
    assert.equal(res.headers.get('x-powered-by'), null); // Should be stripped
  });
});
