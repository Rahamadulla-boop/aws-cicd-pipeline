# Continuous Deployment Guide

This guide covers the technical mechanisms powering continuous deployment to Amazon EC2, including immutable tagging, candidate container isolation, bounded health checks, and service promotion.

---

## 1. Immutable Tagging Strategy

In enterprise DevOps, deploying mutable tags like `:latest` creates non-deterministic deployments and makes reliable rollbacks impossible.

In this pipeline:
- Every image built in CI is tagged with the **full Git commit SHA**:
  ```
  <AWS_ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/aws-cicd-demo:<GIT_COMMIT_SHA>
  ```
- The `:latest` tag is updated as a secondary pointer for convenience, but the deployment engine **always consumes and records the specific immutable commit SHA**.

---

## 2. Zero-Downtime Deployment Workflow

Single-instance deployments often suffer from downtime when an old container is destroyed before the new container finishes starting. To eliminate this issue without incurring the high cost of an AWS Application Load Balancer, we implement a **Candidate Validation Port Strategy**:

```
[ Incoming User Traffic ] ---> Port 80 (iptables redirect) ---> Port 3000 (Active Live Container)
                                                                       |
                                                              [ Still Serving Traffic ]
                                                                       |
[ Pipeline Deploys Candidate ] -> Port 3001 (Isolated Validation Port) <-|
                                        |
                        [ Bounded Healthcheck Probing ]
                                        |
                    +-------------------+-------------------+
                    |                                       |
                [ Passes ]                              [ Fails ]
                    |                                       |
        1. Stop Live Container                  1. Terminate Candidate Container
        2. Promote Candidate to Port 3000       2. Preserve Candidate Crash Logs
        3. Save release to last-known-good.env  3. Previous Container Remains Intact
        4. Exit 0 (Success)                     4. Exit 1 (Pipeline Reports Failure)
```

### Steps Executed by `scripts/deploy.sh`:

1. **State Snapshot**: Captures the image digest of the currently running `aws-cicd-demo-live` container and writes it to `/opt/aws-cicd-demo/last-known-good.env`.
2. **Registry Login**: Authenticates local Docker daemon to Amazon ECR using short-lived authorization token.
3. **Pull Candidate**: Pulls the candidate image by its exact SHA tag.
4. **Candidate Staging**: Launches candidate container named `aws-cicd-demo-candidate` listening on host port `3001`.
5. **Bounded Health Verification**: Executes `verify-deployment.sh http://127.0.0.1:3001/api/health 15 2`.
   - Probes the candidate every 2 seconds for up to 30 seconds.
   - Requires HTTP 200 and `"status": "healthy"`.
6. **Promotion**:
   - Stops the previous live container.
   - Launches candidate on production port `3000`.
   - Runs confirmation healthcheck on port `3000`.
   - Logs `DEPLOY_SUCCESS` event to CloudWatch stream.

---

## 3. Deployment Logs & Auditing

Every deployment writes structured audit logs to `/opt/aws-cicd-demo/deployment-events.log`:

```json
{"timestamp":"2026-10-17T12:00:00Z","event":"DEPLOY_SUCCESS","image":"123456789012.dkr.ecr.ap-south-1.amazonaws.com/aws-cicd-demo:a1b2c3d4e5"}
```

These logs are continuously shipped to Amazon CloudWatch Logs under the log group `/aws/ec2/aws-cicd-demo`.

---

## 4. Manual Deployment via AWS Systems Manager (SSM)

If you need to deploy a specific release manually without triggering a Git push:

```bash
IMAGE_TO_DEPLOY="<ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/aws-cicd-demo:<COMMIT_SHA>"

aws ssm send-command \
  --instance-ids "<YOUR_EC2_INSTANCE_ID>" \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[\"/opt/aws-cicd-demo/deploy.sh '${IMAGE_TO_DEPLOY}'\"]" \
  --region ap-south-1
```
