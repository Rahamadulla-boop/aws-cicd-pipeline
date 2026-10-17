# Complete Setup & Installation Guide

This guide provides end-to-end instructions for configuring your local machine, AWS cloud account, and GitHub repository to run the automated CI/CD pipeline.

---

## Part 1: Local Development Setup

### 1. Prerequisites
- **Node.js**: v20.0.0 or higher
- **npm**: v10.0.0 or higher
- **Docker**: Docker Desktop or Docker Engine
- **Git**: v2.40.0 or higher
- **AWS CLI**: v2.15.0 or higher

### 2. Clone and Install Dependencies
```bash
git clone <YOUR_GITHUB_REPO_URL>
cd aws-cicd-pipeline
npm install
```

### 3. Run Automated Tests
```bash
npm test
```
Expected output: 11 passing tests across the 3 test suites.

### 4. Run Locally
```bash
npm start
```
Open your browser at `http://localhost:3000` to interact with the status dashboard.

---

## Part 2: Local Docker Container Testing

### 1. Build the Docker Image
```bash
docker build -t aws-cicd-demo:local .
```

### 2. Run the Container
```bash
docker run -d --name cicd-test -p 3000:3000 aws-cicd-demo:local
```

### 3. Verify Health Status
```bash
# Query health endpoint
curl -s http://localhost:3000/api/health

# Inspect Docker built-in health probe status
docker inspect --format='{{json .State.Health.Status}}' cicd-test
```
Expected output: `"healthy"`.

### 4. Clean Up Container
```bash
docker rm -f cicd-test
```

---

## Part 3: AWS Cloud Infrastructure Setup

### Step 1: Create the GitHub Actions OIDC Provider in AWS
If your AWS account does not already have the GitHub OIDC provider, execute:
```bash
aws iam create-open-id-connect-provider \
  --url "https://token.actions.githubusercontent.com" \
  --client-id-list "sts.amazonaws.com" \
  --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1" \
  --region ap-south-1
```

### Step 2: Provision Infrastructure with CloudFormation
Deploy the template from the project root:
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
*Note: Provisioning takes approximately 2–3 minutes to set up the VPC security group, ECR repository, IAM roles, and initialize the Ubuntu EC2 host.*

### Step 3: Record CloudFormation Outputs
```bash
aws cloudformation describe-stacks \
  --stack-name aws-cicd-pipeline-stack \
  --region ap-south-1 \
  --query "Stacks[0].Outputs" \
  --output table
```
Make note of:
- `GitHubActionsRoleArn`
- `EC2InstanceId`
- `ECRRepositoryUri`
- `EC2PublicIP`

### Step 4: Copy Helper Scripts to EC2 Host
To enable the deployment engine on the EC2 host, copy the automation scripts to `/opt/aws-cicd-demo/`:

You can execute this command directly from your machine using AWS SSM (without needing SSH keys):
```bash
aws ssm send-command \
  --instance-ids "<YOUR_EC2_INSTANCE_ID>" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=[
    "mkdir -p /opt/aws-cicd-demo",
    "curl -sS https://raw.githubusercontent.com/<YOUR_GITHUB_USERNAME>/<YOUR_GITHUB_REPO_NAME>/main/scripts/deploy.sh -o /opt/aws-cicd-demo/deploy.sh",
    "curl -sS https://raw.githubusercontent.com/<YOUR_GITHUB_USERNAME>/<YOUR_GITHUB_REPO_NAME>/main/scripts/rollback.sh -o /opt/aws-cicd-demo/rollback.sh",
    "curl -sS https://raw.githubusercontent.com/<YOUR_GITHUB_USERNAME>/<YOUR_GITHUB_REPO_NAME>/main/scripts/verify-deployment.sh -o /opt/aws-cicd-demo/verify-deployment.sh",
    "chmod +x /opt/aws-cicd-demo/*.sh"
  ]' \
  --region ap-south-1
```

---

## Part 4: GitHub Repository Configuration

In your GitHub repository, navigate to **Settings > Secrets and variables > Actions**:

### 1. Repository Secrets (`Secrets` tab)
| Secret Name | Value | Description |
| :--- | :--- | :--- |
| `AWS_ROLE_TO_ASSUME` | `arn:aws:iam::<ACCOUNT_ID>:role/aws-cicd-demo-github-oidc-role` | The ARN from CloudFormation output |
| `EC2_INSTANCE_ID` | `i-0123456789abcdef0` | The EC2 Instance ID from CloudFormation |

### 2. Repository Variables (`Variables` tab)
| Variable Name | Value | Description |
| :--- | :--- | :--- |
| `AWS_REGION` | `ap-south-1` | Target AWS Region |
| `ECR_REPOSITORY_NAME` | `aws-cicd-demo` | ECR Private repository name |
| `APPLICATION_HOST` | `<EC2_PUBLIC_IP>` | EC2 Public IPv4 address |

### 3. Create Protected GitHub Environment
1. In your GitHub repository, go to **Settings > Environments**.
2. Click **New environment** and enter name: `production`.
3. Under Deployment branches, select **Selected branches** and add `main`.

---

## Part 5: Triggering Your First Automated Pipeline

1. Commit and push your code to GitHub:
   ```bash
   git add .
   git commit -m "feat: complete automated CI/CD pipeline setup"
   git push origin main
   ```
2. Open the **Actions** tab in GitHub.
3. Observe the automated workflow:
   - ✅ Linting & tests pass
   - ✅ Container built and scanned for vulnerabilities
   - ✅ OIDC keyless authentication granted
   - ✅ Immutable container image published to Amazon ECR
   - ✅ Remote candidate deployed on EC2, verified healthy on port 3001, and promoted to production port 3000!
4. Visit `http://<YOUR_EC2_PUBLIC_IP>` in your browser to view your live DevOps status dashboard!
