# Quick Start Guide — Deploy IntelliOps Sherlock

> **Goal:** Go from zero to a fully running platform with AI-powered observability, security scanning, and auto-remediation in ~60 minutes.
>
> **What you'll learn:** How to provision cloud infrastructure with Terraform, install 28 Kubernetes platform components, and access 10+ enterprise tools through a single domain.

---

## Prerequisites Checklist

Complete each item before starting. Each verification command tells you if you're ready.

### 1. AWS Account & IAM

```bash
# Verify AWS credentials work
aws sts get-caller-identity
# Expected: {"Account": "123456789", "UserId": "...", "Arn": "..."}

# Verify you have the required permissions (should return a role/user)
aws iam get-user || aws sts get-caller-identity
```

Your IAM role/user needs these AWS permissions:
- `eks:*` — Create and manage EKS clusters
- `ec2:*` — VPC, subnets, security groups
- `ecr:*` — Container registries
- `secretsmanager:*` — Secret storage
- `iam:*` — IRSA roles, OIDC provider
- `s3:*` — Terraform state bucket
- `route53:*` — DNS automation
- `sqs:*` — AIOps message queue

### 2. EC2 Instance (Your Deployment Machine)

This project runs FROM an EC2 instance (not your laptop). The instance acts as the deployment machine — it has AWS Instance Profile auth, meaning no access keys needed.

**Recommended:** `t3.large` (2 vCPU, 8GB RAM), Amazon Linux 2023, 30GB storage

```bash
# Verify you're on the instance (check instance metadata)
curl -s http://169.254.169.254/latest/meta-data/instance-id
# Expected: i-0abc123...

# Verify required tools are installed
terraform version   # Need >= 1.10
kubectl version --client
helm version
aws --version
docker --version
git --version
```

**Install missing tools (Amazon Linux 2023):**
```bash
# Terraform
sudo yum install -y yum-utils
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo yum install -y terraform

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install
```

### 3. Domain & Route53

You need a domain with Route53 as the DNS provider. Cheapest option: buy a `.online` domain for ~$1/year at Namecheap/GoDaddy, then create a Route53 hosted zone and update nameservers.

```bash
# Verify your hosted zone exists
aws route53 list-hosted-zones --query 'HostedZones[].Name'
# Expected: ["yourdomain.com."]
```

### 4. ACM Wildcard Certificate

```bash
# Check for wildcard cert in us-east-1
aws acm list-certificates --region us-east-1 \
  --query 'CertificateSummaryList[?DomainName==`*.yourdomain.com`].CertificateArn'
```

If missing, create it:
```bash
aws acm request-certificate \
  --domain-name "*.yourdomain.com" \
  --validation-method DNS \
  --region us-east-1
# Then go to ACM console and add the DNS validation record to Route53
```

### 5. S3 Bucket for Terraform State

```bash
# Create the state bucket (one-time, change the name)
aws s3 mb s3://intelliops-tfstate-yourname --region us-east-1
aws s3api put-bucket-versioning \
  --bucket intelliops-tfstate-yourname \
  --versioning-configuration Status=Enabled
```

---

## Step 1 — Clone & Configure

```bash
git clone https://github.com/nabilpurkar/intelliops-sherlock
cd intelliops-sherlock
```

**Update these values before running Terraform:**

```bash
# terraform/environments/dev/backend.tf — update bucket name
cat k8s/ingress/dns-hostnames.md  # note your domain

# terraform/environments/dev/main.tf — update your IPv6 CIDR if needed
# (line with allowed_ipv6_cidr_blocks — your dev machine IP)
```

---

## Step 2 — Terraform: Provision AWS Infrastructure (~15 min)

```bash
cd terraform/environments/dev
terraform init
terraform plan    # Review what will be created (~40 resources)
terraform apply -auto-approve
```

**What Terraform creates:**
```
module.vpc          → VPC (10.0.0.0/16), 3 public subnets, NAT Gateway, Flow Logs
module.eks          → EKS cluster (intelliops-dev, k8s 1.35), node group (4x t3.large)
module.ecr          → 8 ECR repositories (order, payment, inventory, + 5 aiops)
module.iam          → GitHub OIDC provider, 5 IRSA roles
module.secrets      → 10 Secrets Manager containers (empty, seeded by install script)
module.aiops        → SQS queue (intelliops-anomalies), IRSA for ai-agent
```

**After terraform apply completes:**
```bash
# Update kubeconfig to connect to the new cluster
aws eks update-kubeconfig --name intelliops-dev --region us-east-1

# Verify cluster connectivity
kubectl get nodes
# Expected: 4 nodes in Ready state (takes ~5 min after EKS create)

cd ../../..
```

> 💰 **Cost starts now:** ~$0.50/hr. Remember to destroy when done.

---

## Step 3 — Install Stack: 28 Platform Components (~30 min)

This is the main installer. It installs everything in order with dependency management.

```bash
./scripts/install-stack.sh
```

**What happens at each major step:**

| Steps | What's Installed | Why This Order |
|-------|-----------------|----------------|
| 0 | Bootstrap AWS Secrets Manager | Seeds empty secrets so ESO can sync |
| 1 | cert-manager | Must be first — everything needs TLS |
| 2 | External Secrets Operator | Syncs SM secrets → K8s secrets |
| 3 | ExternalSecret manifests | Creates K8s secrets from SM |
| 4 | PostgreSQL | Must exist before SonarQube/DefectDojo |
| 5 | AWS Load Balancer Controller | Must exist before any ingress |
| 6-7 | metrics-server, cluster-autoscaler | Platform utilities |
| 8 | external-dns | Watches ingresses, creates Route53 records |
| 9-10 | Linkerd (crds + control plane) | Service mesh installed early |
| 11 | ArgoCD | GitOps engine |
| 12-13 | Prometheus stack, Loki, Promtail | Observability |
| 14-15 | Tempo, OTEL Collector | Distributed tracing |
| 15b | OTEL Operator | Python auto-instrumentation |
| 16 | Kong | API gateway (ingress for everything) |
| 16b | Ingress routes | External DNS creates Route53 records |
| 16c | ArgoCD Applications | GitOps begins managing microservices |
| 17-21 | Falco, SonarQube, DefectDojo, Kyverno, Gatekeeper | Security stack |
| 22-23 | Pushgateway, OpenCost | Metrics pipeline + cost monitoring |
| 24-25 | SLO rules, Grafana dashboards | Observability configuration |
| 26-28 | Backstage, LitmusChaos, AIOps | Developer tools + AI |

**If the script stops:** Just re-run it. It automatically resumes from the last checkpoint:
```bash
./scripts/install-stack.sh              # Resumes from last success
./scripts/install-stack.sh --from=16    # Re-run from step 16 onwards
./scripts/install-stack.sh --reset      # Start completely fresh
```

**Watch progress in another terminal:**
```bash
watch -n5 'kubectl get pods -A --field-selector=status.phase!=Running 2>/dev/null | head -30'
```

---

## Step 4 — Configure Stack (~10 min)

Post-install configuration: creates SonarQube projects, DefectDojo products, generates ArgoCD tokens, and writes everything to INSTRUCTIONS.md.

```bash
# If you want CI/CD to work, provide your GitHub PAT
GITHUB_PAT=ghp_yourtoken ./scripts/configure-stack.sh

# Or without GitHub integration (still configures everything else)
./scripts/configure-stack.sh
```

**What configure-stack.sh does:**
1. Builds and pushes service images to ECR (if empty)
2. Creates SonarQube project + access token
3. Creates DefectDojo product + API key
4. Fetches ArgoCD admin password + generates JWT
5. Sets GitHub repository secrets (SONAR_TOKEN, DEFECTDOJO_API_KEY, ARGOCD_AUTH_TOKEN)
6. Generates `INSTRUCTIONS.md` with all URLs + credentials

---

## Step 5 — Verify Everything Is Running

```bash
# Check all pods are running
kubectl get pods -A | grep -v Running | grep -v Completed
# Should be empty (all pods Running)

# Check all ArgoCD applications are synced
kubectl get applications -n argocd
# All should show: Synced + Healthy

# Check ingresses have external addresses
kubectl get ingress -A
# All should have an ADDRESS column with the ALB DNS
```

---

## First Logins — Where to Go

```bash
# See all your URLs and passwords
cat INSTRUCTIONS.md
```

### Grafana
1. Go to https://grafana.yourdomain.com
2. Login: `admin` / password from INSTRUCTIONS.md
3. Navigate: **Dashboards → Browse** — you'll see 8 pre-loaded dashboards
4. Open **"Services Overview"** — you should see request rates from the 3 microservices

### ArgoCD
1. Go to https://argocd.yourdomain.com
2. Login: `admin` / password from INSTRUCTIONS.md
3. You'll see 3 Applications: microservices, aiops, locust
4. All should be green (Synced + Healthy)

### Prometheus
1. Go to https://prometheus.yourdomain.com
2. No login needed
3. Try this query: `sum(rate(order_requests_total[5m])) by (status)`
4. You should see metrics from the order-service

### Generate Load to See Data
```bash
# Port-forward Locust (if ingress not ready)
kubectl port-forward svc/locust 8089:8089 -n locust

# OR open https://locust.yourdomain.com
# Click: Start swarming with 10 users, spawn rate 1
# This generates real traffic through Kong → order-service → payment + inventory
```

---

## Hands-on Lab: Trace Your First Request

1. Open Locust and generate 5 requests to `/orders`
2. Go to Grafana → Explore → Select **Tempo** datasource
3. Click **Search** → Service: `order-service`
4. Click any trace → you'll see the full request span:
   ```
   order-service (45ms)
     └── inventory-service (12ms)
     └── payment-service (18ms)
   ```
5. Click the **Logs** button on the trace → jumps to Loki logs for that exact request

This is end-to-end observability: one click from trace → logs → metrics.

---

## Hands-on Lab: Trigger a Deployment

1. Edit `services/order-service/main.py` — change the version number in the `/health` response
2. Commit and push to main
3. Watch GitHub Actions run all 11 CI stages (takes ~8 min)
4. After CI passes, ArgoCD detects the new image tag and deploys automatically
5. Verify: `kubectl get pods -n apps -w`

---

## Destroying When Done

```bash
# Run in background (takes ~20 min, shows progress in destroy-stack.log)
./scripts/destroy-stack.sh --bg

# Monitor progress
tail -f destroy-stack.log

# After destroy, cost = $0
```

**Or manually control what gets deleted:**
```bash
./scripts/destroy-stack.sh --skip-ns   # Skip namespace deletion (faster)
SKIP_CONFIRM=true ./scripts/destroy-stack.sh  # Non-interactive (CI)
```

---

## Common Setup Issues

| Problem | Fix |
|---------|-----|
| `kubectl cannot reach cluster` | Run `aws eks update-kubeconfig --name intelliops-dev --region us-east-1` |
| `install-stack.sh step fails` | Re-run script — it resumes. Or `--from=N` to re-run from that step |
| Pods in `Pending` state | Run `kubectl describe pod <name> -n <ns>` to see why (usually node capacity) |
| Ingress has no ADDRESS | Wait 3-4 min for ALB provisioning. Check: `kubectl describe ingress -n monitoring` |
| Route53 not resolving | Wait 60-120 sec for ExternalDNS to create records |
| Secret not syncing | Check: `kubectl get externalsecret -A` — look for `SecretSyncError` status |

---

## What's Next?

You have a running platform. Now read the docs in order to understand **why** each component exists and **how** they work together:

→ **[02-architecture.md](02-architecture.md)** — Understand the full system design
→ **[03-infrastructure.md](03-infrastructure.md)** — Deep dive into Terraform modules
→ **[05-cicd-pipeline.md](05-cicd-pipeline.md)** — Understand the CI/CD security gates

---

## Interview Questions — Quick Start / Platform Setup

**Q1: How do you deploy a production Kubernetes environment from scratch?**
> *30-second answer:* "I use Terraform to provision the AWS infrastructure — VPC, EKS, ECR, IAM roles — then a scripted installer that runs 28 Helm chart installations in dependency order with checkpoint/resume support. The full stack goes from zero to running in under an hour."

**Q2: How do you handle resumable deployments when a step fails?**
> *Answer:* "The install script writes a checkpoint file after each successful step. On re-run, it skips already-completed steps. You can also use `--from=N` to restart from a specific step. This is critical for long deployments where transient failures (API throttling, network blips) shouldn't require starting over."

**Q3: How do you manage secrets in Kubernetes without hardcoding them?**
> *Answer:* "We use External Secrets Operator with AWS Secrets Manager as the backend. ESO creates a ClusterSecretStore pointing to SM, and ExternalSecret resources declare which SM paths to sync. The operator automatically creates and refreshes Kubernetes Secrets. No passwords ever touch the git repository."

**Q4: What IAM approach do you use for pods to access AWS services?**
> *Answer:* "IRSA — IAM Roles for Service Accounts. EKS creates an OIDC provider. Terraform creates IAM roles with a trust policy scoped to a specific Kubernetes service account. The pod's service account has an annotation with the role ARN. The pod gets temporary credentials automatically without any access keys."

**Q5: How do you ensure only approved images run in the cluster?**
> *Answer:* "Multiple layers: Kyverno restricts images to our ECR registry only. Images are scanned by Trivy in CI. Cosign signs every image after the build. Kyverno verifies the signature at admission — if an image wasn't signed by our CI pipeline, the pod won't start."
