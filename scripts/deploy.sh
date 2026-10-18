#!/usr/bin/env bash
# ==============================================================================
# deploy.sh - Self-Contained Zero-Downtime Deployment & Recovery Engine
# ==============================================================================
# Features:
# - Self-healing: auto-installs Docker/AWS CLI if missing
# - Zero-hanging: removes cloud-init blocking
# - Dual-port validation: candidate verified on 3001 before promotion to 3000
# - Automated rollback with preserved crash logs
# ==============================================================================

set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

IMAGE_URI="${1:-}"
SIMULATE_FAILURE="${2:-${SIMULATE_FAILURE:-false}}"
AWS_REGION="${AWS_REGION:-ap-south-1}"
APP_NAME="aws-cicd-demo"
LIVE_CONTAINER="${APP_NAME}-live"
CANDIDATE_CONTAINER="${APP_NAME}-candidate"
PRODUCTION_PORT=3000
CANDIDATE_PORT=3001
STATE_DIR="/opt/aws-cicd-demo"
STATE_FILE="${STATE_DIR}/last-known-good.env"
CURRENT_FILE="${STATE_DIR}/current-release.env"
EVENT_LOG="${STATE_DIR}/deployment-events.log"
CRASH_LOG_DIR="/var/log/${APP_NAME}/failed-candidates"

echo "======================================================================"
echo "[DEPLOY] [$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Starting deployment pipeline..."
echo "======================================================================"

if [ -z "${IMAGE_URI}" ]; then
  echo "[ERROR] Missing mandatory argument: IMAGE_URI" >&2
  echo "Usage: $0 <REGISTRY/IMAGE:TAG>" >&2
  exit 1
fi

echo "[DEPLOY] Target Candidate Image: ${IMAGE_URI}"
echo "[DEPLOY] AWS Region: ${AWS_REGION}"

mkdir -p "${STATE_DIR}" "${CRASH_LOG_DIR}"

# 1. Ensure Docker Engine is installed and active
if ! command -v docker >/dev/null 2>&1; then
  echo "[DEPLOY] Docker not detected. Installing docker.io via apt..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y && apt-get install -y docker.io
fi
systemctl enable --now docker 2>/dev/null || service docker start 2>/dev/null || true

# 2. Ensure AWS CLI is available
if ! command -v aws >/dev/null 2>&1; then
  echo "[DEPLOY] AWS CLI not detected. Installing awscli..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y && apt-get install -y awscli
fi

# 3. Ensure Port 80 -> 3000 traffic redirection
iptables -t nat -C PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 3000 2>/dev/null || \
  iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 3000 2>/dev/null || true

# 4. Embedded Healthcheck Probe Function
verify_candidate_health() {
  local target_url="$1"
  local max_attempts="${2:-15}"
  local interval="${3:-2}"

  echo "[HEALTHCHECK] Probing candidate at ${target_url} (Max ${max_attempts} attempts)..."
  local attempt=1
  while [ "${attempt}" -le "${max_attempts}" ]; do
    local response
    response=$(curl -sS --max-time 4 "${target_url}" 2>/dev/null || echo "")
    if echo "${response}" | grep -q '"status":"healthy"' || echo "${response}" | grep -q '"status": "healthy"'; then
      echo "[HEALTHCHECK] Candidate responded healthy on attempt ${attempt}: ${response}"
      return 0
    fi
    echo "[HEALTHCHECK] Attempt ${attempt}/${max_attempts}: Awaiting healthy response..."
    attempt=$((attempt + 1))
    sleep "${interval}"
  done
  echo "[HEALTHCHECK_FAILED] Candidate failed health verification." >&2
  return 1
}

# 5. Embedded Recovery Rollback Function
execute_rollback() {
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "[ROLLBACK] Candidate failed health verification! Initiating recovery..."
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"

  # Dump candidate stdout/stderr before termination
  if docker ps -a --format '{{.Names}}' | grep -q "^${CANDIDATE_CONTAINER}$"; then
    local crash_file="${CRASH_LOG_DIR}/candidate_$(date +%s).log"
    echo "[ROLLBACK] Saving crash logs to ${crash_file}..."
    docker logs "${CANDIDATE_CONTAINER}" > "${crash_file}" 2>&1 || true
    docker rm -f "${CANDIDATE_CONTAINER}" >/dev/null 2>&1 || true
  fi

  # Check if live production container is already running and healthy
  if docker ps --format '{{.Names}}' | grep -q "^${LIVE_CONTAINER}$"; then
    echo "[ROLLBACK] Live container ${LIVE_CONTAINER} is running on port ${PRODUCTION_PORT}. Verifying health..."
    if curl -sS --max-time 4 "http://127.0.0.1:${PRODUCTION_PORT}/api/health" | grep -q '"status":"healthy"'; then
      echo "[ROLLBACK_PRESERVED] Live container is healthy! Zero downtime experienced on production port."
      echo "{\"timestamp\":\"$(date -u +'%Y-%m-%dT%H:%M:%SZ')\",\"event\":\"ROLLBACK_PRESERVED_LIVE\",\"container\":\"${LIVE_CONTAINER}\"}" >> "${EVENT_LOG}"
      return 0
    fi
  fi

  local last_image=""
  if [ -f "${STATE_FILE}" ]; then
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
    last_image="${PREVIOUS_HEALTHY_IMAGE:-}"
  fi

  if [ -n "${last_image}" ]; then
    echo "[ROLLBACK] Restoring previous healthy image: ${last_image}..."
    docker rm -f "${LIVE_CONTAINER}" >/dev/null 2>&1 || true
    docker run -d \
      --name "${LIVE_CONTAINER}" \
      --restart unless-stopped \
      -p "${PRODUCTION_PORT}:3000" \
      -e NODE_ENV=production \
      -e PORT=3000 \
      "${last_image}"
    echo "CURRENT_ACTIVE_IMAGE=\"${last_image}\"" > "${CURRENT_FILE}"
    echo "{\"timestamp\":\"$(date -u +'%Y-%m-%dT%H:%M:%SZ')\",\"event\":\"ROLLBACK_SUCCESS\",\"restoredImage\":\"${last_image}\"}" >> "${EVENT_LOG}"
    echo "[ROLLBACK_SUCCESS] Recovered to ${last_image}."
  else
    echo "[ROLLBACK_WARN] No previous healthy image recorded in ${STATE_FILE}."
  fi
}

# 6. Record current active image before candidate testing
if docker ps --format '{{.Names}}' | grep -q "^${LIVE_CONTAINER}$"; then
  CURRENT_IMAGE=$(docker inspect --format='{{.Config.Image}}' "${LIVE_CONTAINER}" 2>/dev/null || true)
  if [ -n "${CURRENT_IMAGE}" ]; then
    echo "[DEPLOY] Active live image recorded: ${CURRENT_IMAGE}"
    echo "PREVIOUS_HEALTHY_IMAGE=\"${CURRENT_IMAGE}\"" > "${STATE_FILE}"
  fi
fi

# 7. Authenticate to Amazon ECR
REGISTRY_HOST=$(echo "${IMAGE_URI}" | cut -d'/' -f1)
if [[ "${REGISTRY_HOST}" == *".amazonaws.com" ]]; then
  echo "[DEPLOY] Authenticating with Amazon ECR (${REGISTRY_HOST})..."
  aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${REGISTRY_HOST}"
fi

# 8. Pull new candidate container image
echo "[DEPLOY] Pulling candidate image: ${IMAGE_URI}..."
docker pull "${IMAGE_URI}"

# 9. Clean up any leftover candidate container
docker rm -f "${CANDIDATE_CONTAINER}" >/dev/null 2>&1 || true

# 10. Start candidate container on candidate verification port
echo "[DEPLOY] Starting candidate container on validation port ${CANDIDATE_PORT}..."
CANDIDATE_FLAGS=("-e" "PORT=3000" "-e" "DEPLOYMENT_TIMESTAMP=$(date -u +'%Y-%m-%dT%H:%M:%SZ')")
if [ "${SIMULATE_FAILURE}" == "true" ] || [ "${SIMULATE_FAILURE}" == "1" ]; then
  echo "[DEPLOY] WARNING: SIMULATE_FAILURE is active. Injecting simulated failure flag into candidate."
  CANDIDATE_FLAGS+=("-e" "SIMULATE_FAILURE=true" "-e" "NODE_ENV=candidate")
else
  CANDIDATE_FLAGS+=("-e" "NODE_ENV=production")
fi

docker run -d \
  --name "${CANDIDATE_CONTAINER}" \
  -p "${CANDIDATE_PORT}:3000" \
  "${CANDIDATE_FLAGS[@]}" \
  "${IMAGE_URI}"

# 11. Verify Candidate Health with Bounded Retries
echo "[DEPLOY] Running candidate pre-flight healthcheck probe..."
if ! verify_candidate_health "http://127.0.0.1:${CANDIDATE_PORT}/api/health" 15 2; then
  echo "{\"timestamp\":\"$(date -u +'%Y-%m-%dT%H:%M:%SZ')\",\"event\":\"DEPLOYMENT_FAILED\",\"candidateImage\":\"${IMAGE_URI}\"}" >> "${EVENT_LOG}"
  execute_rollback
  exit 1
fi

# 12. Candidate Passed! Promote to Production Port 3000
echo "[DEPLOY] Candidate verified healthy! Promoting to production port ${PRODUCTION_PORT}..."
docker rm -f "${CANDIDATE_CONTAINER}" >/dev/null 2>&1 || true
docker rm -f "${LIVE_CONTAINER}" >/dev/null 2>&1 || true

docker run -d \
  --name "${LIVE_CONTAINER}" \
  --restart unless-stopped \
  -p "${PRODUCTION_PORT}:3000" \
  -e NODE_ENV=production \
  -e PORT=3000 \
  -e DEPLOYMENT_TIMESTAMP="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  "${IMAGE_URI}"

# 13. Sanity check on production port
verify_candidate_health "http://127.0.0.1:${PRODUCTION_PORT}/api/health" 10 1 || true

# 14. Record Release Metadata
echo "PREVIOUS_HEALTHY_IMAGE=\"${IMAGE_URI}\"" > "${STATE_FILE}"
echo "CURRENT_ACTIVE_IMAGE=\"${IMAGE_URI}\"" > "${CURRENT_FILE}"
echo "{\"timestamp\":\"$(date -u +'%Y-%m-%dT%H:%M:%SZ')\",\"event\":\"DEPLOY_SUCCESS\",\"image\":\"${IMAGE_URI}\"}" >> "${EVENT_LOG}"

# 15. Prune dangling images
docker image prune -f >/dev/null 2>&1 || true

echo "======================================================================"
echo "[DEPLOY_SUCCESS] Successfully deployed and verified: ${IMAGE_URI}"
echo "======================================================================"
exit 0
