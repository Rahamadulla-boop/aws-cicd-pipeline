const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');

/**
 * Health verification helper simulating the logic executed during deployment:
 * Repeatedly checks candidate port until healthy or max retries exceeded.
 */
async function verifyCandidateHealth(url, maxAttempts = 3, intervalMs = 100) {
  let attempts = 0;
  while (attempts < maxAttempts) {
    attempts++;
    try {
      const res = await fetch(url);
      if (res.status === 200) {
        const body = await res.json();
        if (body.status === 'healthy') {
          return { success: true, attempts, body };
        }
      }
    } catch {
      // transient connection failure during startup
    }
    if (attempts < maxAttempts) {
      await new Promise(r => setTimeout(r, intervalMs));
    }
  }
  return { success: false, attempts };
}

describe('Deployment Health Verification and Recovery Logic', () => {
  test('Candidate health verification succeeds when candidate returns HTTP 200 healthy', async () => {
    // Spin up healthy candidate mock
    const healthyServer = http.createServer((req, res) => {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ status: 'healthy', version: '2.0.0' }));
    });

    await new Promise(r => healthyServer.listen(0, '127.0.0.1', r));
    const port = healthyServer.address().port;
    const url = `http://127.0.0.1:${port}/api/health`;

    const result = await verifyCandidateHealth(url, 3, 50);
    assert.equal(result.success, true);
    assert.equal(result.body.version, '2.0.0');

    await new Promise(r => healthyServer.close(r));
  });

  test('Candidate health verification fails and prevents promotion when candidate returns HTTP 500', async () => {
    // Spin up failing candidate mock
    const failingServer = http.createServer((req, res) => {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ status: 'unhealthy', error: 'Database connection failed' }));
    });

    await new Promise(r => failingServer.listen(0, '127.0.0.1', r));
    const port = failingServer.address().port;
    const url = `http://127.0.0.1:${port}/api/health`;

    const result = await verifyCandidateHealth(url, 3, 50);
    assert.equal(result.success, false);
    assert.equal(result.attempts, 3);

    await new Promise(r => failingServer.close(r));
  });

  test('Candidate health verification handles unreachable ports (crash on startup)', async () => {
    // Port with nothing listening
    const unusedPort = 59123;
    const url = `http://127.0.0.1:${unusedPort}/api/health`;

    const result = await verifyCandidateHealth(url, 2, 50);
    assert.equal(result.success, false);
    assert.equal(result.attempts, 2);
  });
});
