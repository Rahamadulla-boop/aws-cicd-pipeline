# Automated CI/CD Pipeline with AWS Deployment, Docker Containerization, Automated Rollback, and CloudWatch Monitoring

[![CI/CD Pipeline](https://img.shields.io/badge/CI%2FCD-GitHub%20Actions-blue?logo=github-actions)](.github/workflows/ci-cd.yml)
[![AWS Infrastructure](https://img.shields.io/badge/AWS-ECR%20%7C%20EC2%20%7C%20CloudWatch-orange?logo=amazon-aws)](infrastructure/cloudformation.yaml)
[![Docker](https://img.shields.io/badge/Container-Docker%20Alpine-2496ED?logo=docker)](Dockerfile)
[![Node.js](https://img.shields.io/badge/Runtime-Node.js%2022%20LTS-green?logo=node.js)](package.json)
[![Security](https://img.shields.io/badge/Security-OIDC%20%7C%20Trivy%20%7C%20Gitleaks-brightgreen)](docs/security.md)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

An enterprise-ready, production-grade DevOps system that automatically tests, scans, containerizes, publishes, deploys, verifies, monitors, and recovers a Node.js microservice upon every Git push.

---

## Architecture Diagram

```mermaid
flowchart TD
    Dev["👨‍💻 Developer"] -->|1. git push| Repo["🐙 GitHub Repository"]
    
    subgraph "Continuous Integration (CI Stage)"
        Repo -->|Triggers| CI["GitHub Actions CI Runner"]
        CI --> Test["Unit & Integration Tests (node:test)"]
        Test --> Lint["Code Quality & Syntax Linter"]
        Lint --> Audit["NPM Security Audit"]
        Audit --> BuildDocker["Build Docker Alpine Image"]
        BuildDocker --> Trivy["Trivy Container Vulnerability Scan"]
    end

    subgraph "Cloud Identity & Registry"
        Trivy -->|Checks Pass| OIDC["AWS IAM OIDC Federation<br/>(Temporary STS Token)"]
        OIDC --> ECR["Amazon ECR Private Registry<br/>(Tagged with Git Commit SHA)"]
    end

    subgraph "Continuous Deployment (CD Stage - Amazon EC2)"
        ECR --> SSM["AWS Systems Manager RunCommand"]
        SSM --> Pull["EC2 pulls immutable SHA image"]
        Pull --> Candidate["Launch Candidate on Port 3001"]
        Candidate --> Probe{"Health Verification Probe<br/>GET /api/health (15 retries)"}
        
        Probe -->|Healthy (HTTP 200)| Promote["Promote Candidate:<br/>Switch to Port 3000<br/>Save last-known-good.env"]
        Probe -->|Unhealthy (HTTP 500 / Timeout)| Recover["Automated Rollback Engine:<br/>Dump crash logs<br/>Restore last-known-good<br/>Mark CI/CD Failed"]
    end

    subgraph "Observability & Alerting"
        Promote --> CW["Amazon CloudWatch Logs & Metrics"]
        Recover --> CW
        CW --> Alarms["CloudWatch Alarms & Insights Queries"]
    end
```

---

## Key Features

- **Keyless Cloud Authentication**: Authenticates GitHub Actions to AWS via **OpenID Connect (OIDC)**, eliminating stored permanent access keys.
- **Immutable Container Deployments**: Every release is tagged with the exact Git commit SHA in Amazon ECR; mutable `:latest` is never used as the deployment target.
- **Zero-Downtime Candidate Validation**: New container releases boot on an isolated verification port (`3001`), undergo 15 bounded health probes, and promote to port `3000` only after passing.
- **Automated Rollback Engine**: If candidate health checks fail, the system preserves crash logs to `/var/log/aws-cicd-demo/failed-candidates/`, restores the last known good image, and marks the GitHub Actions run as **FAILED**.
- **Zero-Open-SSH Remote Management**: EC2 deployment commands and terminal sessions are managed securely over **AWS Systems Manager (SSM)**, leaving Port 22 completely closed.
- **Centralized CloudWatch Observability**: Structured JSON logging with automatic redaction of sensitive credentials, metric filters for deployment failures, and CloudWatch system alarms.
- **100% AWS Free Tier Compatible**: Optimized for `t3.micro`/`t2.micro`, with automatic ECR image lifecycle expiration and 14-day CloudWatch log retention.

---

## CI & CD Stages Explained

### 1. Continuous Integration (CI)
Triggered on every commit and pull request targeting `main`:
1. **Source Checkout**: Clones the commit tree.
2. **Dependency Setup**: Installs locked dependencies via `npm ci`.
3. **Automated Testing**: Executes 11 unit and integration tests using Node's built-in `node:test` runner.
4. **Security Audits**: Runs `npm audit` for supply-chain vulnerabilities.
5. **Container Build**: Compiles the minimal Alpine Docker image.
6. **Container Vulnerability Scanning**: Scans image layers for OS and runtime CVEs using Trivy.

### 2. Continuous Deployment (CD)
Triggered **only on authorized pushes to the protected `main` branch**:
1. **OIDC Federation**: Exchanges GitHub's cryptographic JWT for temporary AWS STS credentials scoped to least-privilege IAM policies.
2. **ECR Publishing**: Pushes the image tagged with the Git commit SHA to a private Amazon ECR repository.
3. **SSM Execution**: Dispatches `/opt/aws-cicd-demo/deploy.sh` to the EC2 host via AWS Systems Manager.
4. **Health Verification**: Performs bounded polling against `/api/health` on port `3001`.
5. **Promotion or Recovery**: Promotes verified candidates to production port `3000` or triggers automated rollback.

---

## Technology Stack

- **Application**: Node.js 22 LTS, Express 4.x
- **Testing**: Built-in `node:test` and `node:assert/strict`
- **Containerization**: Docker CE (Alpine Linux base, non-root user)
- **Container Registry**: Amazon ECR (Private, Scan-on-Push)
- **Cloud Hosting**: Amazon EC2 (Ubuntu 24.04 LTS, `t3.micro`)
- **CI/CD Platform**: GitHub Actions
- **Cloud Security**: AWS IAM OpenID Connect (OIDC) Federation
- **Remote Orchestration**: AWS Systems Manager (SSM) RunCommand
- **Monitoring & Logs**: Amazon CloudWatch Agent & CloudWatch Logs
- **Infrastructure as Code**: AWS CloudFormation (`infrastructure/cloudformation.yaml`)

---

## Repository Structure

```
aws-cicd-project/
├── src/
│   ├── server.js               # HTTP lifecycle, graceful shutdown (SIGTERM/SIGINT)
│   ├── app.js                  # Express app, endpoints, simulated failure safeguard
│   └── logger.js               # Structured JSON logger with credential redaction
├── public/
│   ├── index.html              # Responsive DevOps status dashboard
│   ├── styles.css              # Dark-mode responsive styling
│   └── app.js                  # Dynamic metrics polling & API endpoint tester
├── tests/
│   ├── health.test.js          # Healthcheck & failure simulation tests
│   ├── app.test.js             # Core routes, security headers & metadata tests
│   └── deployment.test.js      # Verification retry & recovery logic tests
├── scripts/
│   ├── deploy.sh               # Zero-downtime candidate validation & promotion
│   ├── rollback.sh             # Automated recovery to last known good image
│   ├── verify-deployment.sh    # Bounded healthcheck probe with retries
│   └── cleanup.sh              # Local pruning & AWS infrastructure teardown
├── infrastructure/
│   ├── cloudformation.yaml     # IaC template (ECR, EC2, IAM OIDC, CloudWatch)
│   ├── iam/
│   │   ├── github-actions-trust-policy.json  # OIDC trust relationship
│   │   ├── github-actions-policy.json        # Least-privilege CI/CD permissions
│   │   └── ec2-instance-policy.json          # EC2 ECR pull & CloudWatch permissions
│   └── README.md               # Infrastructure deployment documentation
├── .github/
│   └── workflows/
│       ├── ci-cd.yml           # Primary CI/CD pipeline workflow
│       ├── security-scan.yml   # Gitleaks secret & scheduled vulnerability scan
│       └── cleanup.yml         # Manual workflow for ECR pruning & teardown
├── monitoring/
│   ├── cloudwatch-agent.json   # CloudWatch agent log & metric configuration
│   └── alarms.md               # Metric filters, CloudWatch alarms & queries
├── docs/
│   ├── architecture.md         # In-depth architectural design & trade-offs
│   ├── setup-guide.md          # Step-by-step setup for AWS & GitHub
│   ├── deployment-guide.md     # Continuous deployment & immutable tagging
│   ├── rollback-guide.md       # Automated recovery & disaster drill walkthrough
│   ├── troubleshooting.md      # Diagnostic runbooks for common failures
│   ├── security.md             # Security matrix & defense-in-depth checklist
│   └── interview-questions.md  # DevOps & Cloud interview questions and answers
├── .env.example                # Safe environment variable defaults
├── .gitignore                  # Git exclusions (credentials, logs, node_modules)
├── .dockerignore               # Docker context exclusions
├── package.json                # NPM project definition
├── Dockerfile                  # Production Alpine Dockerfile with healthcheck
└── README.md                   # Master project documentation
```

---

## Quickstart: Local Setup & Testing

### 1. Install & Test Application
```bash
npm install
npm test
npm start
```
Open `http://localhost:3000` to interact with the dashboard.

### 2. Build & Test Docker Container
```bash
docker build -t aws-cicd-demo:local .
docker run -d --name demo-app -p 3000:3000 aws-cicd-demo:local
curl -s http://localhost:3000/api/health
docker rm -f demo-app
```

---

## AWS Infrastructure Deployment

1. **Create GitHub OIDC Provider in AWS** (Run once per AWS account):
   ```bash
   aws iam create-open-id-connect-provider \
     --url "https://token.actions.githubusercontent.com" \
     --client-id-list "sts.amazonaws.com" \
     --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1" \
     --region ap-south-1
   ```

2. **Deploy CloudFormation Stack**:
   ```bash
   aws cloudformation deploy \
     --template-file infrastructure/cloudformation.yaml \
     --stack-name aws-cicd-pipeline-stack \
     --parameter-overrides \
         EnvironmentName=production \
         InstanceType=t3.micro \
         GitHubOrg=<YOUR_GITHUB_USERNAME> \
         GitHubRepo=<YOUR_GITHUB_REPO_NAME> \
     --capabilities CAPABILITY_NAMED_IAM \
     --region ap-south-1
   ```

3. **Configure GitHub Secrets & Variables**:
   - Secret `AWS_ROLE_TO_ASSUME`: Output `GitHubActionsRoleArn`
   - Secret `EC2_INSTANCE_ID`: Output `EC2InstanceId`
   - Variable `AWS_REGION`: `ap-south-1`
   - Variable `APPLICATION_HOST`: Output `EC2PublicIP`

For complete instructions, read [docs/setup-guide.md](docs/setup-guide.md).

---

## Testing Automated Rollback (Disaster Recovery Drill)

To demonstrate automated rollback without changing code:
1. In GitHub, go to **Actions > CI/CD Pipeline > Run workflow**.
2. Set `Simulate candidate health check failure` to `true`.
3. The candidate container fails healthcheck on port `3001`.
4. `deploy.sh` catches the failure, calls `rollback.sh`, restores the healthy container on port `3000`, and marks the CI/CD run as **FAILED**.
5. Your live website remains 100% online on the previous healthy release!

See [docs/rollback-guide.md](docs/rollback-guide.md) for detailed drill evidence.

---

## Cost Optimization & Cleanup

This project is tailored for student portfolios and AWS Free Tier budgets:
- **Compute**: Uses `t3.micro` or `t2.micro` (750 hours/month free under AWS Free Tier).
- **ECR**: Configured with a lifecycle rule keeping only the **10 most recent images** to prevent storage charges.
- **CloudWatch**: Logs retention capped at **14 days**.
- **Networking**: Uses direct SSM communication instead of costly NAT Gateways ($32+/mo) or Application Load Balancers ($16+/mo).

### Complete Teardown Command
```bash
./scripts/cleanup.sh --aws
```
*Destroys the CloudFormation stack, deletes the ECR repository, and terminates the EC2 instance.*

---

## Portfolio Screenshots Checklist

To feature this project on your LinkedIn, GitHub profile, or resume, capture:
1. **GitHub Actions CI/CD Pipeline**: Passing workflow showing test, container scan, ECR push, and SSM deployment.
2. **AWS ECR Console**: Showing immutable SHA-tagged images with vulnerability scan results.
3. **DevOps Status Dashboard**: Web browser view showing live metrics, uptime, and healthy status badge.
4. **CloudWatch Logs Insights**: Query showing `DEPLOY_SUCCESS` and `ROLLBACK_SUCCESS` audit events.
5. **Automated Rollback Evidence**: GitHub Actions run marked failed after an intentional simulated failure drill while the web endpoint remains healthy.

---

## Documentation Links

- [System Architecture & Design Decisions](docs/architecture.md)
- [Complete Setup & Installation Guide](docs/setup-guide.md)
- [Continuous Deployment Guide](docs/deployment-guide.md)
- [Automated Rollback & Recovery Guide](docs/rollback-guide.md)
- [Troubleshooting & Diagnostics](docs/troubleshooting.md)
- [Security Matrix & Checklist](docs/security.md)
- [DevOps Technical Interview Q&A](docs/interview-questions.md)
- [CloudFormation Infrastructure Guide](infrastructure/README.md)
- [CloudWatch Alarms & Monitoring Guide](monitoring/alarms.md)

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
