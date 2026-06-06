# Cost & AWS Console Guide

> **What you'll learn:** Exactly what this platform costs per hour/day/month, where to find every resource in the AWS console, how to verify everything was created correctly, and how to minimize costs during learning sessions.

---

## Cost Summary

All pricing is **us-east-1 (N. Virginia), on-demand, 2025 rates**.

### Running Cost (Cluster Active)

| Resource | Unit Price | Qty | Hourly | Daily | Monthly |
|----------|-----------|-----|--------|-------|---------|
| EKS Control Plane | $0.100/hr flat | 1 | $0.100 | $2.40 | $73 |
| t3.large EC2 nodes | $0.0832/hr | 4 | $0.333 | $8.00 | $240 |
| NAT Gateway | $0.045/hr | 1 | $0.045 | $1.08 | $33 |
| NAT data processing | $0.045/GB | ~2GB/day | ~$0.004 | ~$0.09 | ~$3 |
| ALB | $0.016/LCU-hr | ~1 LCU | $0.016 | $0.38 | $12 |
| EBS gp3 (nodes) | $0.08/GB-month | 4×20GB | $0.003 | $0.07 | $2 |
| ECR storage | $0.10/GB-month | ~1GB | ~$0.000 | ~$0.00 | $0.10 |
| CloudWatch logs | $0.50/GB ingested | ~2GB/day | ~$0.042 | ~$1.00 | ~$30 |
| Route53 hosted zone | $0.50/zone-month | 1 | ~$0.001 | ~$0.02 | $0.50 |
| S3 (TF state) | $0.023/GB-month | < 1MB | ~$0.000 | ~$0.00 | $0.01 |
| Secrets Manager | $0.40/secret-month | 10 | ~$0.001 | ~$0.01 | $0.33 |
| SQS | $0.40 per 1M requests | ~1K/day | ~$0.000 | ~$0.00 | $0.01 |
| **TOTAL** | | | **~$0.54** | **~$13** | **~$394** |

### Cost by Learning Session

| Session | Duration | Cost | Notes |
|---------|----------|------|-------|
| Quick exploration | 2 hours | ~$1.10 | Enough to see all UIs |
| Half-day workshop | 4 hours | ~$2.20 | Complete quickstart + labs |
| Full-day deep dive | 8 hours | ~$4.40 | All 13 docs + hands-on labs |
| Weekend project | 2 days | ~$26 | Full build + CI/CD exploration |
| Monthly learning | 30 days | ~$394 | Leave running constantly |

> **The right approach:** Spin up for a session, destroy when done. `terraform apply` takes ~15 minutes. Running for one 4-hour session costs less than a cup of coffee.

### After `./scripts/destroy-stack.sh` Completes

| Resource | Status | Cost |
|----------|--------|------|
| EKS cluster | Deleted | $0 |
| EC2 nodes | Terminated | $0 |
| EBS volumes | Deleted | $0 |
| NAT Gateway | Deleted | $0 |
| ALB | Deleted | $0 |
| ECR repositories | Deleted (force_delete=true) | $0 |
| Secrets Manager | Deleted immediately (recovery_window=0) | $0 |
| S3 state bucket | **KEPT** (created manually, not by TF) | ~$0.01/month |
| Route53 hosted zone | **KEPT** (created manually) | $0.50/month |
| **Total after destroy** | | **< $0.60/month** |

The S3 state bucket and Route53 zone should be kept — they cost almost nothing and you'll need them for the next session.

---

## Cost Optimization Tips

### Tip 1: Use Spot Instances (70% savings)

Change the node group capacity type:
```hcl
# terraform/modules/eks/main.tf
resource "aws_eks_node_group" "main" {
  capacity_type = "SPOT"    # was "ON_DEMAND"
  # t3.large spot price: ~$0.025/hr vs $0.0832/hr on-demand
  # Savings: 70% on compute (largest cost item)
}
```

**Tradeoff:** Spot instances can be interrupted with 2-minute warning. For a learning environment, this is acceptable — EKS automatically replaces interrupted nodes.

**Monthly savings:** $240 → $72 (4 × t3.large)

### Tip 2: Reduce Node Count (50% savings)

```hcl
node_desired_size = 2    # from 4
node_min_size     = 2
```

2 nodes can run all platform components at reduced redundancy. Some pods may be co-located that should be separated in production.

**Monthly savings:** $240 → $120

### Tip 3: Reduce CloudWatch Log Retention

```hcl
# terraform/modules/eks/main.tf — EKS cluster log group
resource "aws_cloudwatch_log_group" "cluster" {
  retention_in_days = 7    # from 30 — reduces storage cost
}
```

**Monthly savings:** $30 → $7

### Tip 4: Use `--bg` for Efficient Destroy

```bash
# Don't sit and watch for 20 minutes
./scripts/destroy-stack.sh --bg
# Check progress later:
tail -f destroy-stack.log
```

---

## AWS Console Navigation

### VPC

**Path:** AWS Console → VPC → Your VPCs

What to look for: `intelliops-dev-vpc` with CIDR `10.0.0.0/16`

**Subnets:** VPC → Subnets → filter `intelliops-dev`
- 3 public subnets, one per AZ (us-east-1a, us-east-1b, us-east-1c)
- Check tags: `kubernetes.io/cluster/intelliops-dev: shared`

**Route Tables:** VPC → Route Tables → filter `intelliops-dev`
- Public subnets route `0.0.0.0/0` → Internet Gateway
- Private subnets (if any) route → NAT Gateway

**NAT Gateway:** VPC → NAT Gateways
- One NAT in us-east-1a
- Status: Available
- Elastic IP attached

**VPC Flow Logs:** VPC → Your VPCs → intelliops-dev-vpc → Flow logs tab
- Log group: `/aws/vpc/intelliops-dev-flow-logs`

---

### EKS

**Path:** AWS Console → EKS → Clusters → `intelliops-dev`

**Cluster overview:**
- Status: ACTIVE
- Kubernetes version: 1.35
- Platform version: eks.X

**Node group:** Clusters → intelliops-dev → Compute tab → `intelliops-dev-ng`
- Instance type: t3.large
- Desired: 4, Min: 2, Max: 6
- Nodes should all show: Status = Ready

**Add-ons:** Clusters → intelliops-dev → Add-ons tab
- kube-proxy: Active
- vpc-cni: Active
- coredns: Active

**Logging:** Clusters → intelliops-dev → Observability tab
- All log types should be enabled (api, audit, authenticator, controllerManager, scheduler)

**OIDC Provider:** IAM → Identity providers
- Type: OpenID Connect
- Provider URL: `https://oidc.eks.us-east-1.amazonaws.com/id/XXXXX`
- This URL is what enables IRSA

---

### EC2 Nodes

**Path:** EC2 → Instances → filter by tag `eks:cluster-name = intelliops-dev`

For each node:
- Instance state: Running
- Instance type: t3.large
- Public IP: should have one (public subnets)
- IAM role: `intelliops-dev-node-role`

**Key node tag:** `k8s.io/cluster-autoscaler/intelliops-dev: owned` — the Cluster Autoscaler uses this to find which node group to scale.

**Launch Template:** EC2 → Launch Templates → filter `intelliops-dev`
- Check: `http_tokens = required` (IMDSv2 enforced)
- Check: Volume type = gp3, encrypted = true

---

### ECR Repositories

**Path:** ECR → Repositories (Private) → filter `intelliops-dev`

8 repositories:
- `intelliops-dev/order-service`
- `intelliops-dev/payment-service`
- `intelliops-dev/inventory-service`
- `intelliops-dev/load-generator`
- `intelliops-dev/anomaly-detector`
- `intelliops-dev/forecaster`
- `intelliops-dev/alert-correlator`
- `intelliops-dev/ai-agent`

For each repo after `configure-stack.sh`: check that images are present (Images tab). Should see at least one tag.

**Image scanning:** Repositories → repo-name → Images tab → check "Scan status" column. Should show `Complete` with vulnerability counts.

---

### IAM Roles

**Path:** IAM → Roles → search `intelliops-dev`

Roles you should see:

| Role Name | Purpose |
|-----------|---------|
| `intelliops-dev-cluster-role` | EKS control plane |
| `intelliops-dev-node-role` | Worker nodes (ECR pull, VPC CNI, SSM) |
| `intelliops-dev-github-actions-irsa` | GitHub Actions CI (push to ECR) |
| `intelliops-dev-ai-agent-irsa` | AI agent (Bedrock, SQS, K8s) |
| `intelliops-dev-anomaly-detector-irsa` | Anomaly detector (SQS send) |
| `intelliops-dev-eso-irsa` | External Secrets Operator (SM read) |
| `intelliops-dev-external-dns-irsa` | ExternalDNS (Route53 write) |
| `intelliops-dev-alb-irsa` | ALB controller (EC2/ELB manage) |

**Verify IRSA trust policy** (click any IRSA role → Trust relationships):
```json
{
  "Condition": {
    "StringEquals": {
      "oidc.eks.us-east-1.amazonaws.com/id/XXXXX:sub":
        "system:serviceaccount:aiops-demo:ai-agent-sa"
    }
  }
}
```

---

### AWS Secrets Manager

**Path:** Secrets Manager → Secrets → filter `intelliops/dev`

10 secrets should exist. For each, check:
- Status: Active
- Last retrieved: should be recent (ESO syncs hourly)
- Tags: `project: intelliops-dev`

**Do NOT click "Retrieve secret value" in a team environment** — this shows the plaintext password in the console UI (and may be logged in CloudTrail).

**CloudTrail verification:** Go to CloudTrail → Event history → filter by event source `secretsmanager.amazonaws.com` — you'll see all GetSecretValue calls from your pods.

---

### SQS

**Path:** SQS → Queues → `intelliops-anomalies`

What to check:
- Status: Active
- Visibility timeout: 30 seconds
- Message retention: 1 day
- Dead-letter queue: `intelliops-anomalies-dlq`

**Monitoring tab:** Shows messages sent/received/deleted over time. During an active AIOps session you'll see traffic here.

**DLQ:** `intelliops-anomalies-dlq`
- Approximate messages: should be 0 (messages here = processing failures)
- If > 0: check AI agent logs for errors

---

### AWS Bedrock

**Path:** Bedrock → Model access → check `Claude Sonnet` shows Access granted

If not granted: Bedrock → Model access → Manage model access → check Claude models → Request access.

**Note:** Bedrock model access must be granted per-region. The IAM permission in `intelliops-dev-ai-agent-irsa` specifies `us-east-1` only.

---

### CloudWatch

**Path:** CloudWatch → Log Groups

Important log groups:

| Log Group | Content |
|-----------|---------|
| `/aws/eks/intelliops-dev/cluster` | EKS audit, API, scheduler logs |
| `/aws/vpc/intelliops-dev-flow-logs` | VPC network flow logs |

**EKS audit log query** — find all kubectl delete operations in the last hour:
1. CloudWatch → Log Insights
2. Select log group: `/aws/eks/intelliops-dev/cluster`
3. Query:
```sql
fields @timestamp, user.username, objectRef.namespace, objectRef.name, responseStatus.code
| filter verb = "delete"
| sort @timestamp desc
| limit 20
```

---

### Route53

**Path:** Route53 → Hosted zones → your domain

After deploying and configuring ExternalDNS, you should see records auto-created:
```
grafana.yourdomain.com          CNAME → alb-xxx.us-east-1.elb.amazonaws.com
argocd.yourdomain.com           CNAME → alb-xxx.us-east-1.elb.amazonaws.com
prometheus.yourdomain.com       CNAME → alb-xxx.us-east-1.elb.amazonaws.com
```

All pointing to the same ALB DNS name (Kong proxy is the single entry point).

**If records are missing:** Check ExternalDNS logs:
```bash
kubectl logs -n external-dns deployment/external-dns -f
# Look for: "Desired change: CREATE grafana.yourdomain.com"
```

---

### S3 (Terraform State)

**Path:** S3 → `intelliops-tfstate-yourname`

- One object: `dev/terraform.tfstate`
- Versioning enabled (you can restore previous state)
- Size: typically 50-200KB

**Never delete or edit this file manually** — it contains the mapping between your Terraform code and the actual AWS resources. Corruption = you can't run terraform destroy.

---

### ACM (Certificate Manager)

**Path:** ACM → Certificates (make sure region is us-east-1)

Your wildcard certificate `*.yourdomain.com` should show:
- Status: Issued
- Type: Amazon Issued
- In use by: your ALB ARN

---

## Total Resource Count Verification

After `terraform apply` completes, run:
```bash
terraform state list | wc -l
# Expected: ~40-45 resources
```

After `install-stack.sh` completes, check K8s:
```bash
kubectl get pods -A | grep -v Running | grep -v Completed | grep -v Pending
# Should be empty (all pods running)

kubectl get pods -A | wc -l
# Expected: 60-80 pods across all namespaces

kubectl get nodes
# Expected: 4 nodes in Ready state
```

After `configure-stack.sh` completes:
```bash
cat INSTRUCTIONS.md
# All URLs and passwords
```

---

## Cost Alert (Recommended)

Set up a budget alert to avoid surprises:

```bash
# Create a $50/month budget with email alert at 80%
aws budgets create-budget \
  --account-id $(aws sts get-caller-identity --query Account --output text) \
  --budget '{
    "BudgetName": "intelliops-monthly",
    "BudgetLimit": {"Amount": "50", "Unit": "USD"},
    "TimeUnit": "MONTHLY",
    "BudgetType": "COST"
  }' \
  --notifications-with-subscribers '[{
    "Notification": {
      "NotificationType": "ACTUAL",
      "ComparisonOperator": "GREATER_THAN",
      "Threshold": 80,
      "ThresholdType": "PERCENTAGE"
    },
    "Subscribers": [{
      "SubscriptionType": "EMAIL",
      "Address": "your@email.com"
    }]
  }]'
```

AWS Console → Billing → Budgets → set up alerts there if you prefer UI.

---

## What's Next?

→ **[13-troubleshooting.md](13-troubleshooting.md)** — When things break: error messages, root causes, and exact fix commands
→ **[14-chaos-load-testing.md](14-chaos-load-testing.md)** — Generate load, trigger alerts, and watch costs change in OpenCost
→ **[01-quickstart.md](01-quickstart.md)** — Back to the beginning: destroy and rebuild to practice the full cycle
