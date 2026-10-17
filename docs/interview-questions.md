# DevOps & Cloud Architecture Interview Questions and Answers

This document prepares you for technical interviews by walking through the architectural principles, trade-offs, and operational mechanisms implemented in this project.

---

### Q1: Why did you use GitHub OIDC for AWS authentication instead of storing AWS IAM Access Keys in GitHub Secrets?
**Answer:**
Storing long-lived AWS IAM Access Keys in GitHub Secrets introduces critical security vulnerabilities:
1. **Credential Exposure & Theft**: Long-lived keys never expire unless manually rotated. If leaked or compromised, an attacker has persistent access.
2. **Maintenance Overhead**: Rotating keys across dozens of repositories requires complex automation.
3. **No Granular Auditing**: Keys do not inherently link back to specific workflow executions in AWS CloudTrail.

With **OpenID Connect (OIDC)**:
- GitHub's OIDC provider issues a cryptographically signed JSON Web Token (JWT) containing metadata claims (such as repository, ref, and commit SHA).
- AWS STS verifies the token against the trusted OIDC provider and checks the IAM Role trust policy (`token.actions.githubusercontent.com:sub`).
- If valid, AWS STS issues temporary credentials that **expire automatically within 1 hour**.
- No static secrets exist in GitHub, eliminating key leakage vectors completely.

---

### Q2: How did you implement zero-downtime deployment and automated rollback on a single EC2 instance without an Application Load Balancer?
**Answer:**
On a single instance, destroying a running container before validating the new one causes user-facing downtime. Conversely, deploying a broken container directly onto the production port breaks production immediately.

We solved this using a **Candidate Validation Port pattern**:
1. When a new release arrives, the deployment script launches the candidate container on an isolated host port (`3001`).
2. The active production container (`aws-cicd-demo-live`) continues serving traffic normally on port `3000`.
3. An automated verification script executes bounded retries against `http://127.0.0.1:3001/api/health`.
4. **If Healthy**: The script stops the old container and immediately promotes the candidate to port `3000`, updating the `/opt/aws-cicd-demo/last-known-good.env` state file. The switch takes less than 1 second.
5. **If Unhealthy**: The candidate container's crash logs are captured to `/var/log/aws-cicd-demo/failed-candidates/`, the candidate is terminated, and the original container is untouched or reinstated. The script exits with code 1, ensuring the GitHub Actions deployment job is marked as failed.

---

### Q3: Why is deploying Docker images with the `:latest` tag an anti-pattern in production CI/CD?
**Answer:**
The `:latest` tag is mutable; any developer or pipeline can overwrite what `:latest` points to at any time. This causes:
1. **Loss of Immutability**: Two nodes pulling `:latest` five minutes apart could pull completely different code versions.
2. **Broken Rollbacks**: If a rollback script simply runs `docker run ...:latest`, it pulls the exact same broken image that just caused the failure.
3. **Traceability Issues**: In logs or CloudWatch, seeing `:latest` makes it impossible to identify which Git commit introduced a bug.

In this pipeline, every container image is tagged with the **Git commit SHA** (e.g., `:7b3e1f8`). The deployment script and state file record the exact SHA tag, guaranteeing deterministic deployments and instant rollbacks.

---

### Q4: Why did you choose AWS Systems Manager (SSM) over SSH for triggering deployments on EC2?
**Answer:**
Using SSH for automated deployments requires:
- Opening port 22 to the public internet or managing dynamic IP whitelisting for GitHub runner IP ranges (which change continuously).
- Storing a sensitive private SSH key in GitHub Secrets.
- Managing Linux user accounts and SSH host key verification.

With **AWS Systems Manager (SSM) RunCommand**:
- **Zero Open Inbound Ports**: The EC2 instance uses outbound HTTPS polling to AWS SSM endpoints. Port 22 is completely closed in the Security Group.
- **IAM Authorization**: Commands are authenticated through the IAM role assumed via OIDC.
- **Centralized Auditing**: Every command, its parameters, and its exact stdout/stderr logs are recorded in AWS CloudTrail and Systems Manager Command History.

---

### Q5: How did you design the Dockerfile for production security and minimal attack surface?
**Answer:**
The Dockerfile adheres to key enterprise container security practices:
1. **Minimal Base Image**: Uses `node:22-alpine` to minimize OS package vulnerabilities and reduce image size to under 150MB.
2. **Production Dependency Isolation**: Uses `npm ci --omit=dev --ignore-scripts`, ensuring no development test frameworks or build scripts run in production.
3. **Non-Root Execution**: Runs under the built-in unprivileged `node` user (UID: 1000) rather than `root`.
4. **Native Healthcheck**: Configures a Docker `HEALTHCHECK` directive probing `/api/health`, enabling container orchestrators and Docker daemon to detect hangs.
5. **Signal Handling**: Executes `CMD ["node", "src/server.js"]` directly as PID 1 to ensure POSIX signals (`SIGTERM`, `SIGINT`) trigger our graceful shutdown logic.

---

### Q6: How does the application safeguard the simulated-failure feature from accidentally triggering in production?
**Answer:**
The application includes a `SIMULATE_FAILURE` toggle to test the automated rollback pipeline during drills. To guarantee this cannot impact production:
1. `src/app.js` checks both `SIMULATE_FAILURE === 'true'` AND `NODE_ENV !== 'production'`.
2. If `NODE_ENV === 'production'`, the flag is strictly ignored, a warning log is recorded, and the healthcheck returns HTTP 200 `healthy`.
3. Automated unit tests (`tests/health.test.js`) explicitly verify this safeguard.
