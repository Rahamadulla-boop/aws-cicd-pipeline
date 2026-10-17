#!/usr/bin/env bash
# ==============================================================================
# verify-deployment.sh - Candidate Application Health Verification Probe
# ==============================================================================
# Usage: ./verify-deployment.sh <HEALTH_URL> [MAX_ATTEMPTS] [SLEEP_INTERVAL_SECONDS]
# Defaults:
#   HEALTH_URL: http://127.0.0.1:3000/api/health
#   MAX_ATTEMPTS: 15
#   SLEEP_INTERVAL_SECONDS: 2
# ==============================================================================

set -euo pipefail

HEALTH_URL="${1:-http://127.0.0.1:3000/api/health}"
MAX_ATTEMPTS="${2:-15}"
SLEEP_INTERVAL="${3:-2}"

echo "[INFO] [$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Starting deployment verification probe..."
echo "[INFO] Target Health URL: ${HEALTH_URL}"
echo "[INFO] Maximum Attempts: ${MAX_ATTEMPTS} (interval: ${SLEEP_INTERVAL}s, timeout: $((MAX_ATTEMPTS * SLEEP_INTERVAL))s)"

attempt=1
while [ "${attempt}" -le "${MAX_ATTEMPTS}" ]; do
  echo "[DEBUG] Attempt ${attempt}/${MAX_ATTEMPTS}: Querying ${HEALTH_URL}..."

  # Query endpoint, retrieve HTTP status code and response body
  http_response=$(curl -sS -w "\n%{http_code}" --max-time 4 "${HEALTH_URL}" 2>/dev/null || echo "000")
  http_code=$(echo "${http_response}" | tail -n1)
  http_body=$(echo "${http_response}" | sed '$d')

  if [ "${http_code}" = "200" ]; then
    # Verify JSON status field is "healthy"
    if echo "${http_body}" | grep -q '"status":"healthy"' || echo "${http_body}" | grep -q '"status": "healthy"'; then
      echo "[SUCCESS] [$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Candidate verified healthy on attempt ${attempt}!"
      echo "[SUCCESS] Response payload: ${http_body}"
      exit 0
    else
      echo "[WARN] Attempt ${attempt}: Received HTTP 200 but payload status is not healthy: ${http_body}"
    fi
  else
    echo "[WARN] Attempt ${attempt}: Endpoint returned HTTP code ${http_code}. Awaiting application initialization..."
  fi

  attempt=$((attempt + 1))
  if [ "${attempt}" -le "${MAX_ATTEMPTS}" ]; then
    sleep "${SLEEP_INTERVAL}"
  fi
done

echo "[ERROR] [$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Health verification FAILED after ${MAX_ATTEMPTS} attempts." >&2
echo "[ERROR] Last recorded HTTP response code: ${http_code}" >&2
echo "[ERROR] Last recorded body: ${http_body}" >&2
exit 1
