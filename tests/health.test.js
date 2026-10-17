const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const app = require('../src/app');

describe('Health Check API (/api/health)', () => {
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

  test('GET /api/health returns 200 and healthy status under normal conditions', async () => {
    delete process.env.SIMULATE_FAILURE;
    const res = await fetch(`${baseUrl}/api/health`);
    assert.equal(res.status, 200);

    const body = await res.json();
    assert.equal(body.status, 'healthy');
    assert.equal(body.application, process.env.APP_NAME || 'aws-cicd-demo');
    assert.ok(typeof body.version === 'string');
    assert.ok(typeof body.uptimeSeconds === 'number');
    assert.ok(!isNaN(Date.parse(body.timestamp)));
  });

  test('GET /api/health triggers simulated 500 failure when SIMULATE_FAILURE is set in test/dev environment', async () => {
    process.env.SIMULATE_FAILURE = 'true';
    process.env.NODE_ENV = 'test';

    const res = await fetch(`${baseUrl}/api/health`);
    assert.equal(res.status, 500);

    const body = await res.json();
    assert.equal(body.status, 'unhealthy');
    assert.ok(body.error.includes('Simulated failure active'));

    // Reset
    delete process.env.SIMULATE_FAILURE;
  });

  test('Safeguard: SIMULATE_FAILURE is ignored and returns 200 if NODE_ENV is production', async () => {
    const originalEnv = process.env.NODE_ENV;
    process.env.SIMULATE_FAILURE = 'true';
    process.env.NODE_ENV = 'production';

    const res = await fetch(`${baseUrl}/api/health`);
    assert.equal(res.status, 200);

    const body = await res.json();
    assert.equal(body.status, 'healthy');

    // Clean up
    delete process.env.SIMULATE_FAILURE;
    process.env.NODE_ENV = originalEnv;
  });
});
