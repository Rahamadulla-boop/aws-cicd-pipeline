# Troubleshooting & Diagnostic Guide

This guide covers common issues encountered in CI/CD pipeline execution, AWS authentication, container runtimes, and CloudWatch agent logging.

---

## 1. GitHub Actions OIDC Authentication Failures

### Symptom:
```
Error: Credentials could not be loaded, please check your action inputs: 
Could not load credentials from any providers
- or -
An error occurred (AccessDenied) when calling the AssumeRoleWithWebIdentity operation
```

### Root Cause Analysis & Fix:
1. **GitHub OIDC Provider Missing**:
   Verify the OIDC provider exists in AWS IAM:
   ```bash
   aws iam list-open-id-connect-providers
   ```
   If missing, run:
   ```bash
   aws iam create-open-id-connect-provider \
     --url "https://token.actions.githubusercontent.com" \
     --client-id-list "sts.amazonaws.com" \
     --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1"
   ```

2. **Trust Policy Condition Mismatch**:
   Inspect the IAM Role trust policy:
   - Check `token.actions.githubusercontent.com:sub`. It must match `repo:<OWNER>/<REPO>:*`.
   - Ensure the repository name matches capitalization exactly.

3. **Workflow Missing `id-token: write`**:
   The GitHub Actions job must have:
   ```yaml
   permissions:
     id-token: write
     contents: read
   ```

---

## 2. AWS SSM Command Times Out or Fails

### Symptom:
```
SSM Status: DeliveryTimedOut or Undeliverable
```

### Root Cause Analysis & Fix:
1. **SSM Agent Not Connected**:
   Check if the EC2 instance is reporting online to Systems Manager:
   ```bash
   aws ssm describe-instance-information --region ap-south-1
   ```
   If empty:
   - Verify that the IAM instance profile `aws-cicd-demo-ec2-instance-profile` is attached to the EC2 instance.
   - Verify outbound HTTPS (port 443) connectivity is allowed in the Security Group.

2. **Scripts Not Found on Host**:
   Ensure `/opt/aws-cicd-demo/deploy.sh` exists and has executable permissions (`chmod +x`).

---

## 3. Investigating a Failed Deployment Candidate

### Where Crash Logs are Preserved:
When a candidate fails health checks, `rollback.sh` automatically captures the container's stdout/stderr before deletion:
```bash
ls -la /var/log/aws-cicd-demo/failed-candidates/
cat /var/log/aws-cicd-demo/failed-candidates/candidate_*.log
```

You can view these directly from your local terminal using AWS SSM:
```bash
aws ssm send-command \
  --instance-ids "<YOUR_EC2_INSTANCE_ID>" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["tail -n 50 /var/log/aws-cicd-demo/failed-candidates/*"]' \
  --region ap-south-1
```

---

## 4. Port 80 Traffic Not Reaching Application

### Symptom:
`http://<EC2_PUBLIC_IP>` times out or refuses connection, but `http://<EC2_PUBLIC_IP>:3000` works.

### Root Cause Analysis & Fix:
Check the iptables port forwarding rule:
```bash
sudo iptables -t nat -L PREROUTING -n -v
```
If the rule is missing, re-apply it:
```bash
sudo iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 3000
sudo netfilter-persistent save
```

---

## 5. CloudWatch Agent Not Streaming Logs

### Diagnostic Commands:
```bash
# Check CloudWatch agent status
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -m ec2 \
  -a status

# View CloudWatch agent log file
sudo tail -n 50 /opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log
```
Common fix: Verify that `CloudWatchAgentServerPolicy` is attached to the EC2 IAM role.
