# System Architecture & Technical Design

This document details the end-to-end architecture of the **Automated CI/CD Pipeline with AWS Deployment, Docker Containerization, Automated Rollback, and CloudWatch Monitoring**.

---

## 1. High-Level Pipeline Flow

```mermaid
flowchart TD
    Developer["👨‍💻 Developer"] -->|git push| GitHub["🐙 GitHub Repository"]
    
    subgraph "Continuous Integration (GitHub Actions)"
        GitHub -->|Triggers| CI["1. CI Runner"]
        CI --> Test["Unit & Integration Tests (node:test)"]
        Test --> Lint["Static Linter & Syntax Check"]
        Lint --> Audit["NPM Dependency Security Audit"]
        Audit --> BuildImage["Docker Image Build"]
        BuildImage --> Trivy["Trivy Container Vulnerability Scan"]
    end

    subgraph "Cloud Authentication (Keyless OIDC)"
        Trivy -->|Passing Checks Only| OIDC["AWS STS AssumeRoleWithWebIdentity"]
        OIDC --> TempCreds["Temporary AWS Credentials (1 hr)"]
    end

    subgraph "Container Registry (Amazon ECR)"
        TempCreds --> PushECR["Push Image to ECR<br/>Tagged with Commit SHA"]
    end

    subgraph "Continuous Deployment & Zero-Downtime Verification (Amazon EC2)"
        PushECR --> SSM["AWS Systems Manager (SSM) RunCommand"]
        SSM --> PullImage["EC2 pulls candidate image from ECR"]
        PullImage --> RunCandidate["Run Candidate Container on Port 3001"]
        RunCandidate --> HealthCheck{"Bounded Health Probe<br/>/api/health (15 attempts)"}
        
        HealthCheck -->|Healthy 200| Promote["Promote Candidate:<br/>Switch to Port 3000<br/>Record Last Known Good"]
        HealthCheck -->|Unhealthy 500 / Timeout| Rollback["Automated Rollback Engine:<br/>Preserve Crash Logs<br/>Reactivate Last Known Good<br/>Mark CI/CD Failed"]
    end

    subgraph "Observability (Amazon CloudWatch)"
        Promote --> CW["CloudWatch Logs & Metrics"]
        Rollback --> CW
        CW --> Alarms["CloudWatch Alarms & Insights Queries"]
    end
```

---

## 2. Zero-Downtime Deployment Sequence

To avoid single-instance downtime during container updates, a **Candidate Validation Port** strategy is implemented:

```mermaid
sequenceDiagram
    autonumber
    participant GHA as GitHub Actions
    participant SSM as AWS Systems Manager
    participant EC2 as EC2 Docker Host
    participant ECR as Amazon ECR
    participant CW as CloudWatch Logs

    GHA->>SSM: SendCommand(deploy.sh <IMAGE_URI>)
    SSM->>EC2: Execute deploy.sh
    EC2->>ECR: Authenticate & Pull Candidate Image
    EC2->>EC2: Record active container image -> last-known-good.env
    EC2->>EC2: Start candidate container on validation port 3001
    loop Bounded Health Verification (15 attempts, 2s interval)
        EC2->>EC2: curl -fsS http://127.0.0.1:3001/api/health
    end
    alt Health Check Passes
        EC2->>EC2: Stop and remove old container
        EC2->>EC2: Promote candidate to production port 3000
        EC2->>EC2: Update last-known-good.env
        EC2->>CW: Log DEPLOY_SUCCESS event
        EC2-->>SSM: Exit code 0 (Success)
        SSM-->>GHA: Deployment Successful
    else Health Check Fails
        EC2->>EC2: Capture candidate stdout/stderr to /var/log/aws-cicd-demo/failed-candidates/
        EC2->>EC2: Terminate candidate container
        EC2->>EC2: Verify / restart previous image from last-known-good.env
        EC2->>CW: Log DEPLOYMENT_FAILED & ROLLBACK_SUCCESS event
        EC2-->>SSM: Exit code 1 (Pipeline Failure)
        SSM-->>GHA: Deployment Failed (Rollback preserved host)
    end
```

---

## 3. Security Boundary & Identity Federation

```mermaid
graph LR
    subgraph "GitHub Cloud"
        Workflow["GitHub Actions Job"]
        OIDC_Token["GitHub OIDC Token<br/>(aud: sts.amazonaws.com)"]
    end

    subgraph "AWS Security Perimeter"
        IAM_OIDC["IAM Identity Provider<br/>token.actions.githubusercontent.com"]
        Role["GitHubActionsRole<br/>Trust: repo:owner/repo:refs/heads/main"]
        ECR_Policy["ECR Repository Policy<br/>Least Privilege"]
        SSM_Policy["SSM Command Execution Policy"]
    end

    Workflow -->|Present JWT Token| IAM_OIDC
    IAM_OIDC -->|Validate Subject & Audience| Role
    Role -->|Temporary Session Token| Workflow
    Workflow -->|Push Image| ECR_Policy
    Workflow -->|Send Deploy Command| SSM_Policy
```

---

## 4. Key Architectural Trade-Offs

| Decision | Alternative Considered | Selected Approach | Rationale |
| :--- | :--- | :--- | :--- |
| **Authentication** | Long-lived IAM Access Keys stored in GitHub Secrets | AWS IAM OpenID Connect (OIDC) Federation | Eliminates credential leak risks, no secret rotation needed, credentials expire within 1 hour. |
| **Compute Deployment** | Direct SSH (port 22) from GitHub Actions | AWS Systems Manager (SSM) RunCommand | Zero open inbound ports needed for remote deployment; audited centrally via AWS CloudTrail; no private SSH keys stored in CI. |
| **Container Strategy** | Blue/Green with Application Load Balancer (ALB) | Dual-port candidate verification on single EC2 instance | Extremely cost-conscious for student/entry-level portfolio ($0 under Free Tier vs $16+/mo for an AWS ALB), while achieving automated candidate health testing and instant rollback. |
| **Rollback State Storage** | Remote database / S3 | Local deterministic state file (`/opt/aws-cicd-demo/last-known-good.env`) | Zero network dependency during emergency recovery; fast and reliable rollback even during cloud network partitions. |
