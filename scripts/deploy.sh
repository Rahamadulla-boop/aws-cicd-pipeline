#!/usr/bin/env bash
# ==============================================================================
# deploy.sh - Production Candidate Deployment & Validation Engine
# ==============================================================================
# Orchestrates zero-downtime candidate validation, ECR authentication,
# bounded health probes, and automatic rollback triggering on failure.
# ==============================================================================

set -euo pipefail

IMAGE_URI="${1:-}"
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

mkdir -p "${STATE_DIR}"

# 1. Capture current running image for reliable rollback fallback
if docker ps --format '{{.Names}}' | grep -q "^${LIVE_CONTAINER}$"; then
  CURRENT_IMAGE=$(docker inspect --format='{{.Config.Image}}' "${LIVE_CONTAINER}" 2>/dev/null || true)
  if [ -n "${CURRENT_IMAGE}" ]; then
    echo "[DEPLOY] Currently active live image: ${CURRENT_IMAGE}"
    echo "PREVIOUS_HEALTHY_IMAGE=\"${CURRENT_IMAGE}\"" > "${STATE_FILE}"
  fi
fi

# 2. Authenticate to Amazon ECR if deploying from an ECR registry
REGISTRY_HOST=$(echo "${IMAGE_URI}" | cut -d'/' -f1)
if [[ "${REGISTRY_HOST}" == *".amazonaws.com" ]]; then
  echo "[DEPLOY] Authenticating Docker daemon with Amazon ECR (${REGISTRY_HOST})..."
  aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${REGISTRY_HOST}"
fi

# 3. Pull new candidate container image
echo "[DEPLOY] Pulling candidate image: ${IMAGE_URI}..."
docker pull "${IMAGE_URI}"

# 4. Clean up any leftover candidate container
docker rm -f "${CANDIDATE_CONTAINER}" >/dev/null 2>&1 || true

# 5. Start candidate container on candidate verification port
echo "[DEPLOY] Starting candidate container on verification port ${CANDIDATE_PORT}..."
docker run -d \
  --name "${CANDIDATE_CONTAINER}" \
  -p "${CANDIDATE_PORT}:3000" \
  -e NODE_ENV=production \
  -e PORT=3000 \
  -e DEPLOYMENT_TIMESTAMP="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  "${IMAGE_URI}"

# 6. Verify Candidate Health with Bounded Retries
echo "[DEPLOY] Initiating candidate pre-flight healthcheck verification..."
if ! "${SCRIPT_DIR}/verify-deployment.sh" "http://127.0.0.1:${CANDIDATE_PORT}/api/health" 15 2; then
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "[DEPLOY_FAILED] Candidate health verification FAILED!"
  echo "Initiating automatic rollback to preserve system availability..."
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"

  # Log failure event
  echo "{\"timestamp\":\"$(date -u +'%Y-%m-%dT%H:%M:%SZ')\",\"event\":\"DEPLOYMENT_FAILED\",\"candidateImage\":\"${IMAGE_URI}\"}" >> "${EVENT_LOG}"

  # Trigger automated rollback
  "${SCRIPT_DIR}/rollback.sh"

  echo "[DEPLOY] Rollback executed. Terminating deployment pipeline with error." >&2
  exit 1
fi

# 7. Candidate Verified! Promote Candidate to Production Port
echo "[DEPLOY] Candidate passed health verification. Promoting to production port ${PRODUCTION_PORT}..."

# Remove candidate container
docker rm -f "${CANDIDATE_CONTAINER}" >/dev/null 2>&1 || true

# Stop previous live container
docker rm -f "${LIVE_CONTAINER}" >/dev/null 2>&1 || true

# Launch promoted production container
docker run -d \
  --name "${LIVE_CONTAINER}" \
  --restart unless-stopped \
  -p "${PRODUCTION_PORT}:3000" \
  -e NODE_ENV=production \
  -e PORT=3000 \
  -e DEPLOYMENT_TIMESTAMP="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  "${IMAGE_URI}"

# 8. Post-Promotion Sanity Check on Production Port
echo "[DEPLOY] Running post-promotion confirmation check on port ${PRODUCTION_PORT}..."
if ! "${SCRIPT_DIR}/verify-deployment.sh" "http://127.0.0.1:${PRODUCTION_PORT}/api/health" 10 1; then
  echo "[CRITICAL] Production container failed post-switch sanity check. Triggering emergency rollback!" >&2
  "${SCRIPT_DIR}/rollback.sh"
  exit 1
fi

# 9. Record Successful Release Metadata
echo "PREVIOUS_HEALTHY_IMAGE=\"${IMAGE_URI}\"" > "${STATE_FILE}"
echo "CURRENT_ACTIVE_IMAGE=\"${IMAGE_URI}\"" > "${CURRENT_FILE}"
echo "{\"timestamp\":\"$(date -u +'%Y-%m-%dT%H:%M:%SZ')\",\"event\":\"DEPLOY_SUCCESS\",\"image\":\"${IMAGE_URI}\"}" >> "${EVENT_LOG}"

# 10. Clean up dangling images safely
echo "[DEPLOY] Cleaning up unused dangling Docker images..."
docker image prune -f >/dev/null 2>&1 || true

echo "======================================================================"
echo "[DEPLOY_SUCCESS] Successfully deployed and verified: ${IMAGE_URI}"
echo "======================================================================"
exit 0
