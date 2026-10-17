# Amazon CloudWatch Monitoring & Alerting Guide

This document defines the monitoring architecture, CloudWatch Metric Filters, and automated Alarms configured for `aws-cicd-demo`.

---

## 1. Centralized Log Groups & Streams

The CloudWatch Agent collects and ships logs to the centralized log group:
- **Log Group**: `/aws/ec2/aws-cicd-demo`
- **Streams**:
  - `{instance_id}/deployment-events`: Structured JSON audit logs of every candidate promotion, rollback trigger, and healthcheck outcome.
  - `{instance_id}/failed-candidates`: Preserved stdout/stderr crash logs from candidate containers that failed health checks before rollback.
  - `{instance_id}/syslog`: Host operating system and Docker daemon logs.

---

## 2. CloudWatch Metric Filters

To convert structured JSON application logs into actionable numeric CloudWatch metrics without writing custom daemon code:

### Metric Filter 1: Candidate Deployment Failures
Extracts events where a candidate container fails pre-flight health checks:
```bash
aws logs put-metric-filter \
  --log-group-name "/aws/ec2/aws-cicd-demo" \
  --filter-name "CandidateDeploymentFailures" \
  --filter-pattern '{ $.event = "DEPLOYMENT_FAILED" }' \
  --metric-transformations \
      metricName=DeploymentFailures,metricNamespace=CICD/Pipeline,metricValue=1,defaultValue=0 \
  --region ap-south-1
```

### Metric Filter 2: Critical Rollback Failures
Extracts catastrophic failures where both candidate and restored release failed:
```bash
aws logs put-metric-filter \
  --log-group-name "/aws/ec2/aws-cicd-demo" \
  --filter-name "RollbackFailures" \
  --filter-pattern '{ $.event = "ROLLBACK_FAILED" }' \
  --metric-transformations \
      metricName=RollbackFailures,metricNamespace=CICD/Pipeline,metricValue=1,defaultValue=0 \
  --region ap-south-1
```

---

## 3. Production CloudWatch Alarms

### Alarm 1: Deployment Failure Alert
Triggers when an automated deployment health check fails and triggers rollback:
```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "aws-cicd-demo-deployment-failure" \
  --alarm-description "Triggers when candidate healthcheck fails and triggers recovery" \
  --metric-name "DeploymentFailures" \
  --namespace "CICD/Pipeline" \
  --statistic "Sum" \
  --period 60 \
  --evaluation-periods 1 \
  --threshold 1 \
  --comparison-operator "GreaterThanOrEqualToThreshold" \
  --treat-missing-data "notBreaching" \
  --region ap-south-1
```

### Alarm 2: High EC2 Host CPU Utilization
Detects resource starvation or CPU spikes:
```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "aws-cicd-demo-ec2-high-cpu" \
  --alarm-description "Triggers if EC2 CPU utilization exceeds 85% for 10 minutes" \
  --metric-name "CPUUtilization" \
  --namespace "AWS/EC2" \
  --statistic "Average" \
  --dimensions Name=InstanceId,Value=<YOUR_EC2_INSTANCE_ID> \
  --period 300 \
  --evaluation-periods 2 \
  --threshold 85 \
  --comparison-operator "GreaterThanOrEqualToThreshold" \
  --treat-missing-data "missing" \
  --region ap-south-1
```

### Alarm 3: EC2 Instance Status Check Failure
Detects underlying AWS hardware or hypervisor host failures:
```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "aws-cicd-demo-instance-status-check" \
  --alarm-description "Triggers when EC2 system or instance status check fails" \
  --metric-name "StatusCheckFailed" \
  --namespace "AWS/EC2" \
  --statistic "Maximum" \
  --dimensions Name=InstanceId,Value=<YOUR_EC2_INSTANCE_ID> \
  --period 60 \
  --evaluation-periods 2 \
  --threshold 1 \
  --comparison-operator "GreaterThanOrEqualToThreshold" \
  --treat-missing-data "breaching" \
  --region ap-south-1
```

---

## 4. Useful CloudWatch Logs Insights Queries

Navigate to **AWS CloudWatch Console > Logs Insights**, select `/aws/ec2/aws-cicd-demo`, and run these queries:

### View All Deployment & Rollback Audit Records
```sql
fields @timestamp, event, candidateImage, restoredImage
| filter ispresent(event)
| sort @timestamp desc
| limit 20
```

### View 5xx Application Errors & Exceptions
```sql
fields @timestamp, metadata.method, metadata.path, metadata.statusCode, metadata.durationMs
| filter metadata.statusCode >= 500
| sort @timestamp desc
| limit 50
```

---

## 5. Safely Testing Alarms

To verify your alarm routing and notification configuration without crashing production services:

```bash
# 1. Manually transition the alarm into ALARM state:
aws cloudwatch set-alarm-state \
  --alarm-name "aws-cicd-demo-deployment-failure" \
  --state-value ALARM \
  --state-reason "Manual drill verifying CloudWatch notification routing" \
  --region ap-south-1

# 2. Reset alarm back to OK state:
aws cloudwatch set-alarm-state \
  --alarm-name "aws-cicd-demo-deployment-failure" \
  --state-value OK \
  --state-reason "Drill completed successfully" \
  --region ap-south-1
```
