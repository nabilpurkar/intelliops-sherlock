# Infrastructure Guide — Terraform & AWS

> **What you'll learn:** Every AWS resource this project creates, why it was designed that way, how to tune it, what it costs, and how to navigate the AWS console to verify it.

---

## Terraform Overview

**Official description:** "Terraform is an infrastructure as code tool that lets you define cloud resources in human-readable configuration files and manage them through a consistent lifecycle." — HashiCorp

**Why we use it:** Every AWS resource in this project is defined in `.tf` files and tracked in S3 state. This means the entire cluster (VPC, EKS, ECR, IAM, secrets) can be created with `terraform apply` and destroyed with `terraform destroy`. No clicking in the console, no drift, no "I don't remember how I created that."

**What we use:** AWS provider `~> 6.0`, TLS provider `~> 4.0`, Null provider `~> 3.0`

---

## Module Structure

```
terraform/
├── environments/
│   └── dev/
│       ├── main.tf         ← Calls all 7 modules with dev-specific values
│       ├── backend.tf      ← S3 remote state + DynamoDB lock
│       ├── versions.tf     ← Provider versions (aws ~> 6.0)
│       ├── variables.tf    ← (minimal — most values hardcoded for dev simplicity)
│       └── outputs.tf      ← Outputs: cluster name, VPC ID, etc.
└── modules/
    ├── vpc/                ← Network foundation
    ├── eks/                ← Kubernetes cluster
    ├── ecr/                ← Container registry
    ├── iam/                ← GitHub OIDC + IRSA roles
    ├── secrets/            ← Secrets Manager containers
    └── aiops/              ← SQS + AIOps IAM
```

**Key rule:** No `terraform {}` block inside any module file. Provider constraints live ONLY in `environments/dev/versions.tf`. This is the standard Terraform module design — modules are provider-agnostic, callers configure providers.

---

## Module 1: VPC

**Creates:** Network foundation for everything.

```
VPC (10.0.0.0/16)
├── Public Subnet us-east-1a (10.0.1.0/24)
├── Public Subnet us-east-1b (10.0.2.0/24)
├── Public Subnet us-east-1c (10.0.3.0/24)
├── Internet Gateway
├── NAT Gateway (single, in 1a) ← Cost trade-off: 1 instead of 3
├── Route Tables (public + private)
└── VPC Flow Logs → CloudWatch (30-day retention)
```

**AWS Console:** VPC → Your VPCs → `intelliops-dev-vpc`

**Key design decisions:**
- **Public subnets only in dev:** Private subnets with NAT Gateway cost $0.045/hr each × 3 AZs = $0.135/hr extra. In dev, public subnets with EKS-managed security groups are sufficient.
- **Single NAT Gateway:** 3 NAT Gateways for HA cost $0.135/hr total. For learning, 1 is fine. In prod, use one per AZ for availability.
- **EKS subnet tags:** Subnets have `kubernetes.io/cluster/intelliops-dev: shared` and `kubernetes.io/role/elb: 1` tags — these are required for EKS to find subnets for node groups and ALB provisioning.

**Tune for production:**
```hcl
# Uncomment private subnets in main.tf:
private_subnet_cidrs = ["10.0.10.0/24", "10.0.20.0/24", "10.0.30.0/24"]

# And use private subnets for EKS node group:
private_subnet_ids = module.vpc.private_subnet_ids  # not public_subnet_ids
```

---

## Module 2: EKS

**Creates:** The Kubernetes cluster and everything it needs.

```
EKS Cluster (intelliops-dev, Kubernetes 1.35)
├── CloudWatch Log Group (/aws/eks/intelliops-dev/cluster)
│   └── Logs: api, audit, authenticator, controllerManager, scheduler
├── IAM Role (cluster role — AmazonEKSClusterPolicy)
├── Security Groups
│   ├── cluster-sg (control plane: accepts HTTPS from nodes)
│   └── node-sg (nodes: pod networking, outbound AWS services)
├── EKS Cluster (API server, etcd — managed by AWS)
├── OIDC Provider (for IRSA)
├── IAM Role (node role — EKSWorkerNodePolicy, CNI, ECR ReadOnly, SSM)
├── Launch Template (IMDSv2, gp3 EBS, encrypted)
└── Managed Node Group (intelliops-dev-ng)
    ├── Instance type: t3.large (2 vCPU, 8GB RAM)
    ├── Min: 2, Max: 6, Desired: 4
    └── Cluster Autoscaler manages scaling within these bounds
```

**AWS Console Navigation:**
- EKS → Clusters → `intelliops-dev`
- EC2 → Instances → Filter by tag `eks:cluster-name = intelliops-dev`
- IAM → Roles → `intelliops-dev-cluster-role`, `intelliops-dev-node-role`
- CloudWatch → Log Groups → `/aws/eks/intelliops-dev/cluster`

**Key variables you can tune:**

| Variable | Default | Change to |
|----------|---------|-----------|
| `cluster_version` | `1.35` | Latest EKS version |
| `node_instance_type` | `t3.large` | `t3.xlarge` for more pods |
| `node_min_size` | `2` | `3` for prod HA |
| `node_max_size` | `6` | `10` for larger workloads |
| `node_desired_size` | `4` | Match expected load |
| `node_disk_size` | `20` GB | `50` for larger image caches |
| `endpoint_public_access` | `true` | `false` for prod (private only) |

**OIDC Provider:** The EKS module creates an IAM OIDC provider automatically. This is what enables IRSA — pods can assume IAM roles without access keys. The OIDC issuer URL looks like: `https://oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B716D3041E`

**IMDSv2 enforcement:** The launch template sets `http_tokens = required` — pods cannot access instance metadata without the token hop, preventing SSRF-to-credential-theft attacks.

---

## Module 3: ECR

**Creates:** 8 private container registries.

```
ECR Repositories:
├── intelliops-dev/order-service
├── intelliops-dev/payment-service
├── intelliops-dev/inventory-service
├── intelliops-dev/load-generator
├── intelliops-dev/anomaly-detector
├── intelliops-dev/forecaster
├── intelliops-dev/alert-correlator
└── intelliops-dev/ai-agent
```

All repos have:
- `force_delete = true` — so `terraform destroy` can delete them even with images
- Image scan on push — free Trivy-based vulnerability scanning built into ECR

**AWS Console:** ECR → Repositories → filter `intelliops-dev`

**Why private ECR over Docker Hub?**
- No rate limits (Docker Hub limits unauthenticated pulls to 100/6hr)
- No internet egress required — nodes pull from ECR via VPC endpoint (or NAT)
- Kyverno can restrict pods to ONLY pull from `*.dkr.ecr.*.amazonaws.com`
- Integrated scanning + Cosign attestation support
- Free storage for images < 500MB/month per repo

---

## Module 4: IAM

**Creates:** GitHub Actions OIDC integration + 5 IRSA roles.

### GitHub OIDC Provider

Instead of storing `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` in GitHub, we create an OIDC trust. GitHub's OIDC token is verified by AWS — CI jobs get temporary credentials via `aws sts assume-role-with-web-identity`.

```hcl
# Trust policy: allows the intelliops-sherlock repo's main branch
Principal = "token.actions.githubusercontent.com"
Condition = {
  StringLike = {
    "token.actions.githubusercontent.com:sub":
      "repo:nabilpurkar/intelliops-sherlock:ref:refs/heads/main"
  }
}
```

**This means:** Only pushes to main branch of the platform repo can assume this role. A fork, PR from untrusted contributor, or different branch cannot.

### IRSA Roles (IAM Roles for Service Accounts)

Each IRSA role has a trust policy scoped to a specific Kubernetes service account:

```hcl
# Example: ai-agent IRSA trust policy
Principal = "oidc.eks.us-east-1.amazonaws.com/id/XXXXX"
Condition = {
  StringEquals = {
    "oidc.../sub": "system:serviceaccount:aiops-demo:ai-agent-sa"
  }
}
```

| IRSA Role | K8s Service Account | Permissions |
|-----------|--------------------|----|
| `intelliops-dev-ai-agent-irsa` | `aiops-demo:ai-agent-sa` | Bedrock:InvokeModel, SQS:ReceiveMessage, K8s read/write |
| `intelliops-dev-anomaly-detector-irsa` | `aiops-demo:anomaly-detector-sa` | SQS:SendMessage, Prometheus read |
| `intelliops-dev-eso-irsa` | `external-secrets:eso-sa` | SecretsManager:GetSecretValue |
| `intelliops-dev-external-dns-irsa` | `external-dns:external-dns-sa` | Route53:ChangeResourceRecordSets |
| `intelliops-dev-alb-irsa` | `kube-system:aws-load-balancer-controller` | EC2/ELB create/describe/delete |

**AWS Console:** IAM → Roles → search `intelliops-dev`

---

## Module 5: Secrets

**Creates:** Empty Secrets Manager containers (no values).

This is intentional. Terraform creates the secret shells so ESO can reference them by ARN. Values are seeded by `install-stack.sh` step 0 (which generates random passwords and stores them).

```
AWS Secrets Manager (all in us-east-1):
├── intelliops/dev/postgresql     ← postgres_password, sonarqube_password, kong_password, defectdojo_password
├── intelliops/dev/defectdojo     ← admin_password, secret_key, credential_aes256_key
├── intelliops/dev/argocd         ← admin_password
├── intelliops/dev/grafana        ← admin_password
├── intelliops/dev/sonarqube      ← admin_password
├── intelliops/dev/backstage      ← github_token
├── intelliops/dev/slack          ← webhook_url
├── intelliops/dev/litmus         ← mongodb_root_password, mongodb_root_user
├── intelliops/dev/linkerd        ← ca_crt_b64, issuer_crt_b64, issuer_key_b64 (base64 encoded)
└── intelliops/dev/falco-defectdojo ← api_key
```

**AWS Console:** AWS Secrets Manager → Secrets → filter `intelliops/dev`

**`recovery_window_in_days = 0`:** This means secrets are deleted immediately on `terraform destroy` (no 30-day recovery window). This is intentional — everything is regenerated on next deploy, so there's nothing to recover.

---

## Module 6: AIOps

**Creates:** Infrastructure for the AI auto-remediation pipeline.

```
SQS Queue: intelliops-anomalies
├── Message retention: 1 day
├── Visibility timeout: 30 seconds
└── Dead-Letter Queue: intelliops-anomalies-dlq (after 3 failures)

IAM Role: intelliops-dev-ai-agent-irsa
└── Permissions:
    ├── bedrock:InvokeModel (us-east-1 region only)
    ├── sqs:ReceiveMessage, sqs:DeleteMessage (intelliops-anomalies queue)
    ├── s3:GetObject (for context retrieval)
    └── logs:GetLogEvents (for CloudWatch log reading)

IAM Role: intelliops-dev-anomaly-detector-irsa
└── Permissions:
    └── sqs:SendMessage (intelliops-anomalies queue)
```

**AWS Console:** SQS → Queues → `intelliops-anomalies`

---

## Terraform Remote State

```
S3 Bucket: intelliops-tfstate-cloudus
├── Key: dev/terraform.tfstate
└── Encryption: S3-managed (SSE-S3)

DynamoDB (optional): For state locking
```

**Why remote state?** If `.terraform` state is local, two people running `terraform apply` simultaneously will corrupt the state. S3 backend + DynamoDB locking prevents this.

**AWS Console:** S3 → `intelliops-tfstate-cloudus` → `dev/terraform.tfstate`

---

## Terraform Workflow Reference

```bash
# First-time setup
cd terraform/environments/dev
terraform init

# Preview what will be created/changed/destroyed
terraform plan

# Create all resources
terraform apply -auto-approve

# Update kubeconfig after EKS is created
aws eks update-kubeconfig --name intelliops-dev --region us-east-1

# Destroy everything (use destroy-stack.sh instead for proper cleanup)
terraform destroy -auto-approve

# Destroy specific module only
terraform destroy -target=module.eks -auto-approve

# Show current state
terraform state list
terraform state show module.eks.aws_eks_cluster.main
```

---

## AWS Cost Breakdown (us-east-1, 2025 On-Demand)

| Resource | Hourly | Daily | Monthly | Notes |
|----------|--------|-------|---------|-------|
| EKS Control Plane | $0.100 | $2.40 | $73 | Flat rate |
| 4× t3.large (nodes) | $0.333 | $8.00 | $240 | $0.0832/hr |
| NAT Gateway | $0.045 | $1.08 | $33 | + $0.045/GB processed |
| ALB | $0.016 | $0.38 | $12 | 1 LCU average |
| EBS 4×20GB gp3 | $0.003 | $0.07 | $2 | $0.08/GB-month |
| ECR storage | ~$0.00 | ~$0.00 | $0.50 | $0.10/GB, small images |
| CloudWatch logs | ~$0.00 | ~$0.00 | $1-5 | Depends on verbosity |
| S3 (TF state) | ~$0.00 | ~$0.00 | $0.01 | < 1MB state file |
| Route53 | $0.001 | $0.02 | $0.50 | Per hosted zone |
| **Total** | **~$0.50** | **~$12** | **~$362** | |

> 💡 **Savings tip:** Use Spot Instances for nodes: `t3.large` spot ≈ $0.025/hr vs $0.0832/hr = **70% savings**. Add `capacity_type = "SPOT"` to the node group. Use mixed managed node groups in prod.

---

## What You Should Verify in AWS Console After `terraform apply`

1. **VPC:** VPC → Your VPCs → `intelliops-dev-vpc` (CIDR 10.0.0.0/16)
2. **Subnets:** VPC → Subnets → 3 subnets with `intelliops-dev` in name
3. **EKS Cluster:** EKS → Clusters → `intelliops-dev` → Status: ACTIVE
4. **Node Group:** EKS → Clusters → intelliops-dev → Compute → `intelliops-dev-ng`
5. **ECR Repos:** ECR → Repositories → 8 repos with `intelliops-dev/` prefix
6. **IAM Roles:** IAM → Roles → 6+ roles with `intelliops-dev` prefix
7. **OIDC Provider:** IAM → Identity providers → `oidc.eks.us-east-1.amazonaws.com`
8. **Secrets:** Secrets Manager → 10 secrets with `intelliops/dev/` prefix
9. **SQS:** SQS → `intelliops-anomalies` queue

---

## Interview Questions — Infrastructure & Terraform

**Q1: How do you manage Terraform state in a team environment?**
> *Answer:* "We use an S3 backend with versioning enabled. The state file is stored at `s3://intelliops-tfstate-yourname/dev/terraform.tfstate`. DynamoDB provides state locking — if two engineers run `terraform apply` simultaneously, the second one waits. If there's a crash, the lock entry in DynamoDB can be manually removed. We never store state locally — it's always in S3."

**Q2: What's the difference between `terraform plan` and `terraform apply`?**
> *Answer:* "`terraform plan` shows you exactly what will be created, modified, or destroyed — it's a dry run with no side effects. It reads the current state from S3 and compares against the desired configuration. You should always review the plan before applying, especially in production. `terraform apply` executes those changes. We use `-auto-approve` in CI after the plan has been reviewed by humans in a PR."

**Q3: How do you handle sensitive values like passwords in Terraform?**
> *Answer:* "We never put passwords in `.tf` files or state. The Secrets module creates empty AWS Secrets Manager containers. The install script generates random passwords at runtime using `openssl rand` and stores them in SM. This way, Terraform state only contains the SM path/ARN, never the actual secret value. The state file itself is stored in S3 with server-side encryption."

**Q4: What is IRSA and why is it better than node-level IAM roles?**
> *Answer:* "IRSA — IAM Roles for Service Accounts — gives each pod its own temporary AWS credentials. Without IRSA, all pods on a node share the node's IAM role, which means if one pod is compromised, it has all permissions any pod on that node needs. With IRSA, the ai-agent pod can call Bedrock and SQS, but the order-service pod cannot — even though they're on the same node. Credentials are rotated automatically via the OIDC token mechanism."

**Q5: What Terraform changes require replacing a resource (cause downtime)?**
> *Answer:* "For EKS: changing the cluster name, VPC, or Kubernetes version requires cluster replacement — that's a major operation. For the node group: changing the launch template forces node replacement, which triggers a rolling node drain. We use `lifecycle { create_before_destroy = true }` on security groups and launch templates so new resources are created before old ones are destroyed, minimizing disruption. For security group rules: most changes are in-place. For subnets: changes usually require replacement."
