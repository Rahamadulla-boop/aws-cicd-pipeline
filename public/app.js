/**
 * Frontend logic for aws-cicd-demo status dashboard
 */

function formatUptime(seconds) {
  if (seconds < 60) return `${seconds}s`;
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  if (m < 60) return `${m}m ${s}s`;
  const h = Math.floor(m / 60);
  return `${h}h ${m % 60}m`;
}

function formatDate(isoString) {
  if (!isoString) return '-';
  try {
    const d = new Date(isoString);
    return d.toLocaleString();
  } catch {
    return isoString;
  }
}

async function fetchDashboardData() {
  const healthIndicator = document.getElementById('health-indicator');
  const healthText = document.getElementById('health-text');

  try {
    // 1. Fetch Health Status
    const healthRes = await fetch('/api/health');
    const healthData = await healthRes.json();

    if (healthRes.ok && healthData.status === 'healthy') {
      healthIndicator.className = 'status-pill status-healthy';
      healthText.textContent = 'System Healthy';
    } else {
      healthIndicator.className = 'status-pill status-unhealthy';
      healthText.textContent = 'System Unhealthy';
    }

    // 2. Fetch Detailed Info
    const infoRes = await fetch('/api/info');
    if (infoRes.ok) {
      const info = await infoRes.json();
      
      document.getElementById('env-badge').textContent = info.environment.toUpperCase();
      document.getElementById('version-badge').textContent = `v${info.version}`;

      document.getElementById('val-version').textContent = info.version;
      document.getElementById('val-env').textContent = info.environment;
      document.getElementById('val-commit').textContent = info.commitSha ? info.commitSha.substring(0, 10) : 'local';
      document.getElementById('val-uptime').textContent = formatUptime(info.uptimeSeconds);
      document.getElementById('val-build-time').textContent = formatDate(info.buildTimestamp);
      document.getElementById('val-deploy-time').textContent = formatDate(info.deploymentTimestamp);
    }
  } catch (err) {
    console.error('Failed to fetch dashboard data:', err);
    healthIndicator.className = 'status-pill status-unhealthy';
    healthText.textContent = 'Connection Error';
  }
}

async function testEndpoint(endpoint) {
  const endpointLabel = document.getElementById('response-endpoint');
  const statusLabel = document.getElementById('response-status');
  const codeBody = document.getElementById('response-body');

  endpointLabel.textContent = `GET ${endpoint}`;
  statusLabel.className = 'status-code';
  statusLabel.textContent = 'Fetching...';
  codeBody.textContent = 'Loading response...';

  try {
    const startTime = performance.now();
    const res = await fetch(endpoint);
    const duration = Math.round(performance.now() - startTime);
    const data = await res.json();

    statusLabel.textContent = `HTTP ${res.status} (${duration}ms)`;
    statusLabel.className = `status-code ${res.ok ? 'code-200' : 'code-500'}`;
    codeBody.textContent = JSON.stringify(data, null, 2);
  } catch (err) {
    statusLabel.textContent = 'Network Error';
    statusLabel.className = 'status-code code-500';
    codeBody.textContent = JSON.stringify({ error: err.message }, null, 2);
  }
}

// Initial fetch and auto-refresh every 10 seconds
document.addEventListener('DOMContentLoaded', () => {
  fetchDashboardData();
  setInterval(fetchDashboardData, 10000);
});
