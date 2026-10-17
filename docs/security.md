# Security Architecture & Hardening Guide

This document details the defense-in-depth security measures implemented across the codebase, Docker runtime, CI/CD pipelines, and AWS cloud infrastructure.

---

## 1. Security Architecture Matrix

| Domain | Threat Mitigated | Implementation |
| :--- | :--- | :--- |
| **Authentication** | Stolen or leaked permanent AWS access keys | **AWS IAM OpenID Connect (OIDC)**: GitHub Actions requests short-lived (1-hour) temporary STS credentials. No secret keys stored in repository. |
| **Identity / IAM** | Blast radius from compromised CI runner | **Least-Privilege IAM Policies**: Role can only push to `aws-cicd-demo` ECR repository and dispatch SSM commands to instances tagged `Project: aws-cicd-demo`. |
| **Network Security** | Brute force SSH attacks, port scans | **Zero-Open-SSH Architecture**: Security Group allows inbound traffic **only on Port 80 and 3000**. Administrative shell access is handled exclusively via encrypted AWS Systems Manager Session Manager. |
| **Container Security** | Container breakout / privilege escalation | **Non-Root Execution**: Docker container runs as unprivileged `node` user (UID: 1000). Root filesystem write access is restricted. |
| **Image Scanning** | Known CVEs in dependencies & base image | **Multi-Layer Scanning**: Pre-push Trivy scan in GitHub Actions + automated Amazon ECR Scan-on-Push with vulnerability alerts. |
| **Secret Scanning** | Accidental commitment of API keys / tokens | **Gitleaks Integration**: Automated secret scanning on pull requests and scheduled weekly scans. |
| **Log Privacy** | Accidental leakage of tokens/passwords in logs | **Automated Log Redaction**: `src/logger.js` filters out sensitive keys matching `token`, `password`, `secret`, `authorization`, and `cookie`. |
| **Application Hardening** | Clickjacking, MIME-sniffing, XSS | **Security Headers**: Express disables `X-Powered-By` and injects `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, and `X-XSS-Protection`. |

---

## 2. Security Checklist

- [x] No permanent AWS access keys or secret keys committed to Git or GitHub Secrets.
- [x] IAM OIDC trust policy strictly conditioned on `repo:<OWNER>/<REPO>:*`.
- [x] Docker image built using an official minimal Alpine base image.
- [x] Dockerfile executes as unprivileged user `USER node`.
- [x] Port 22 (SSH) is blocked from the internet (`0.0.0.0/0`).
- [x] Remote deployment executed via audited AWS Systems Manager RunCommand.
- [x] Docker socket (`/var/run/docker.sock`) is never mounted into public web containers.
- [x] Dependency trees audited with `npm audit` and container scanned with `trivy`.
- [x] Simulated failure flag hard-blocked from activating in production environment (`NODE_ENV === 'production'`).
- [x] Shell scripts hardened with `set -euo pipefail` and parameter expansion checks.

---

## 3. Production Hardening Roadmap & Remaining Limitations

While this architecture represents best-in-class security for a single-instance portfolio system, the following enhancements should be implemented for large-scale enterprise deployments:

1. **HTTPS / TLS Termination**: Currently, HTTP is served on port 80. For enterprise production, place an AWS Application Load Balancer (ALB) with an AWS Certificate Manager (ACM) SSL/TLS certificate in front of the instance, or configure Certbot/Let's Encrypt with Nginx.
2. **Private Subnets & NAT Gateway**: The EC2 instance currently resides in a public subnet with a public IP to remain 100% Free Tier compliant. In corporate environments, place the EC2 instance inside a private VPC subnet with no public IP, routing through an AWS NAT Gateway or VPC Endpoints for ECR, SSM, and CloudWatch.
3. **AWS WAF (Web Application Firewall)**: Attach AWS WAF to inspect and block OWASP Top 10 web exploits and rate limit abusive clients.
