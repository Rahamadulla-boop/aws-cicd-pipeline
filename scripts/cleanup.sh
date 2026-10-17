#!/usr/bin/env bash
# ==============================================================================
# cleanup.sh - Maintenance and Resource Decommissioning Script
# ==============================================================================
# Usage:
#   ./cleanup.sh --local          # Prunes local docker resources, containers, and test logs
#   ./cleanup.sh --aws            # Destroys AWS CloudFormation stack & ECR repository
#   ./cleanup.sh --all            # Complete cleanup of both local and cloud resources
# ==============================================================================

set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-south-1}"
STACK_NAME="${STACK_NAME:-aws-cicd-pipeline-stack}"
ECR_REPO_NAME="${ECR_REPO_NAME:-aws-cicd-demo}"

clean_local() {
  echo "[CLEANUP] Cleaning local Docker containers and images..."
  docker rm -f aws-cicd-demo-candidate aws-cicd-demo-live 2>/dev/null || true
  docker image prune -af --filter "label=maintainer=DevOps" 2>/dev/null || true
  docker image prune -f 2>/dev/null || true

  echo "[CLEANUP] Cleaning temporary test output..."
  rm -rf coverage .nyc_output dist
  echo "[SUCCESS] Local cleanup complete."
}

clean_aws() {
  echo "======================================================================"
  echo " WARNING: You are about to DESTROY AWS cloud resources:"
  echo " - CloudFormation Stack: ${STACK_NAME} (EC2 instance, Security Groups, IAM Roles)"
  echo " - Amazon ECR Repository: ${ECR_REPO_NAME} (All container images)"
  echo " - AWS Region: ${AWS_REGION}"
  echo "======================================================================"

  if [ -t 0 ]; then
    read -rp "Are you absolutely sure you want to proceed? (type 'yes' to confirm): " confirmation
    if [ "${confirmation}" != "yes" ]; then
      echo "[ABORT] AWS cleanup cancelled by user."
      exit 0
    fi
  else
    echo "[INFO] Non-interactive environment detected. Proceeding with AWS cleanup..."
  fi

  echo "[CLEANUP] 1. Emptying and deleting Amazon ECR repository: ${ECR_REPO_NAME}..."
  aws ecr delete-repository \
    --repository-name "${ECR_REPO_NAME}" \
    --region "${AWS_REGION}" \
    --force 2>/dev/null || echo "[INFO] ECR repository ${ECR_REPO_NAME} already removed or not found."

  echo "[CLEANUP] 2. Deleting CloudFormation Stack: ${STACK_NAME}..."
  aws cloudformation delete-stack \
    --stack-name "${STACK_NAME}" \
    --region "${AWS_REGION}"

  echo "[INFO] Awaiting CloudFormation stack deletion completion..."
  aws cloudformation wait stack-delete-complete \
    --stack-name "${STACK_NAME}" \
    --region "${AWS_REGION}" 2>/dev/null || true

  echo "[SUCCESS] AWS cloud resources decommissioned successfully."
}

MODE="${1:---local}"

case "${MODE}" in
  --local)
    clean_local
    ;;
  --aws)
    clean_aws
    ;;
  --all)
    clean_local
    clean_aws
    ;;
  *)
    echo "Usage: $0 [--local | --aws | --all]"
    exit 1
    ;;
esac
