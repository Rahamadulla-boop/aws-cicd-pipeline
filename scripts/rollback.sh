#!/usr/bin/env bash
# ==============================================================================
# rollback.sh - Automated Deployment Recovery & Rollback Engine
# ==============================================================================
# Restores application to the last verified healthy image release.
# Preserves crash logs and notifies operator via structured event logging.
# ==============================================================================

set -euo pipefail

APP_NAME="aws-cicd-demo"
STATE_DIR="/opt/aws-cicd-demo"
STATE_FILE="${STATE_DIR}/last-known-good.env"
EVENT_LOG="${STATE_DIR}/deployment-events.log"
CRASH_LOG_DIR="/var/log/${APP_NAME}/failed-candidates"
CONTAINER_NAME="${APP_NAME}-live"
APP_PORT=3000

echo "[ROLLBACK] [$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Initiating automated recovery..."

mkdir -p "${STATE_DIR}" "${CRASH_LOG_DIR}"

# 1. Determine target rollback image
ROLLBACK_IMAGE="${1:-}"

if [ -z "${ROLLBACK_IMAGE}" ]; then
  if [ -f "${STATE_FILE}" ]; then
    # Load PREVIOUS_HEALTHY_IMAGE from state file
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
    ROLLBACK_IMAGE="${PREVIOUS_HEALTHY_IMAGE:-}"
  fi
fi

if [ -z "${ROLLBACK_IMAGE}" ]; then
  echo "[CRITICAL] [$(date -u +'%Y-%m-%dT%H:%M:%SZ')] No previous healthy release recorded in ${STATE_FILE}!" >&2
  echo "[CRITICAL] Manual intervention required. Available local images:" >&2
  docker images "${APP_NAME}" || true
  exit 2
fi

echo "[ROLLBACK] Target recovery image: ${ROLLBACK_IMAGE}"

# 2. Archive logs of candidate container before teardown
CANDIDATE_CONTAINER="${APP_NAME}-candidate"
if docker ps -a --format '{{.Names}}' | grep -q "^${CANDIDATE_CONTAINER}$"; then
  TIMESTAMP=$(date -u +'%Y%m%d_%H%M%S')
  CANDIDATE_LOG="${CRASH_LOG_DIR}/candidate_${TIMESTAMP}.log"
  echo "[ROLLBACK] Preserving candidate logs to ${CANDIDATE_LOG}..."
  docker logs "${CANDIDATE_CONTAINER}" > "${CANDIDATE_LOG}" 2>&1 || true
  echo "[ROLLBACK] Removing candidate container..."
  docker rm -f "${CANDIDATE_CONTAINER}" >/dev/null 2>&1 || true
fi

# 3. Restore last healthy container
echo "[ROLLBACK] Reinstating verified healthy image: ${ROLLBACK_IMAGE}..."
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

docker run -d \
  --name "${CONTAINER_NAME}" \
  --restart unless-stopped \
  -p "${APP_PORT}:3000" \
  -e NODE_ENV=production \
  -e PORT=3000 \
  "${ROLLBACK_IMAGE}"

# 4. Verify restored application health
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "[ROLLBACK] Verifying restored application health on port ${APP_PORT}..."
if "${SCRIPT_DIR}/verify-deployment.sh" "http://127.0.0.1:${APP_PORT}/api/health" 15 2; then
  RECOVERY_MSG="[ROLLBACK_SUCCESS] Application successfully restored to healthy release: ${ROLLBACK_IMAGE}"
  echo "${RECOVERY_MSG}"
  echo "{\"timestamp\":\"$(date -u +'%Y-%m-%dT%H:%M:%SZ')\",\"event\":\"ROLLBACK_SUCCESS\",\"restoredImage\":\"${ROLLBACK_IMAGE}\"}" >> "${EVENT_LOG}"
  
  # Update active release marker
  echo "CURRENT_ACTIVE_IMAGE=\"${ROLLBACK_IMAGE}\"" > "${STATE_DIR}/current-release.env"
  exit 0
else
  RECOVERY_FAIL="[CRITICAL_FAILURE] Restored release ${ROLLBACK_IMAGE} also failed healthcheck!"
  echo "${RECOVERY_FAIL}" >&2
  echo "{\"timestamp\":\"$(date -u +'%Y-%m-%dT%H:%M:%SZ')\",\"event\":\"ROLLBACK_FAILED\",\"attemptedImage\":\"${ROLLBACK_IMAGE}\"}" >> "${EVENT_LOG}"
  exit 2
fi
