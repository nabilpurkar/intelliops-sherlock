# One-Click Automation Guide

> **What you'll learn:** What the one-click setup scripts do, what was previously manual (and is now automated), how to stand up the entire platform from scratch with a single command, how to automate day-2 operations, and what genuinely still requires human input.

---

## The Goal

```
git clone → one command → full platform running
```

No manual kubectl, no copy-pasting tokens, no browser-based setup.

---

## What the Scripts Do

Two scripts cover the full lifecycle:

```
install-stack.sh        ← Installs everything (Terraform → Helm → ArgoCD → Apps)
configure-stack.sh      ← Post-install config (tokens, GitHub secrets, INSTRUCTIONS.md)
```

Together they handle ~40 previously manual steps automatically.

---

## install-stack.sh — Full Stack Install

### What it does (in order)

```
Step  1: Pre-flight checks (kubectl, aws, helm, docker, terraform)
Step  2: Terraform apply — VPC, EKS, ECR, IAM, ACM, Route53
Step  3: EKS kubeconfig update
Step  4: Core cluster addons (ALB controller, ExternalDNS, cert-manager, ESO)
Step  5: Linkerd mTLS mesh (PKI cert generation + install)
Step  6: Kong Gateway (API gateway + ingresses)
Step  7: Monitoring stack (Prometheus, Grafana, Loki, Tempo, Promtail)
Step  8: ArgoCD + AppProject
Step  9: Platform applications (via ArgoCD App of Apps)
Step 10: Security tooling (Kyverno, Falco, Trivy operator)
Step 11: DefectDojo + SonarQube
Step 12: AIOps demo workloads
Step 13: OTEL collector
Step 14: Locust load generator
Step 15: configure-stack.sh (runs automatically at end)
```

### Checkpoint/resume system

Every step is checkpointed to `.install-state`. If the script fails at step 8, re-running it skips steps 1-7 and resumes from step 8. This is critical for long installs over flaky connections.

```bash
# Resume from last checkpoint
./scripts/install-stack.sh

# Reset and start fresh
./scripts/install-stack.sh --reset

# Re-run from a specific step
./scripts/install-stack.sh --from=8
```

### Run it

```bash
# Full one-click from scratch (takes ~25-35 minutes)
GITHUB_PAT=github_pat_xxx ./scripts/install-stack.sh
```

`GITHUB_PAT` is optional — if provided, `configure-stack.sh` automatically sets GitHub Actions secrets at the end. If omitted, it prints the values and you set them manually.

---

## configure-stack.sh — Post-Install Configuration

### What it does (in order)

```
Step  0:  ECR bootstrap — builds + pushes stub images if ECR repos are empty
Step  0b: Ingress reconciliation — re-applies all Kong ingresses
Step  1:  SonarQube — creates project "intelliops-sherlock" + generates CI token
Step  2:  DefectDojo — retrieves API token + creates product "IntelliOps Sherlock"
Step  3:  ArgoCD — creates 1-year ci-deployer JWT token, triggers initial sync
Step  4:  Grafana — retrieves admin password, stores in AWS SM
Step  5:  Kong — retrieves admin credentials
Step  6:  GitHub secrets — pushes SONAR_TOKEN, DEFECTDOJO_API_KEY, ARGOCD_AUTH_TOKEN,
          PUSHGATEWAY_URL, AWS_ACCOUNT_ID, AWS_REGION (requires GITHUB_PAT)
Step  7:  Writes INSTRUCTIONS.md with all URLs, credentials, and CLI commands
```

### Run standalone (to refresh tokens after cluster recreate)

```bash
GITHUB_PAT=github_pat_xxx ./scripts/configure-stack.sh

# Or just refresh the GitHub secrets
GITHUB_PAT=github_pat_xxx ./scripts/configure-stack.sh --from=6
```

---

## What Was Previously Manual (Now Automated)

| Previously manual | Automated by | Where |
|-------------------|-------------|-------|
| Generate SonarQube CI token | `configure-stack.sh` step 1 | AWS SM `intelliops/dev/sonarqube → ci_token` |
| Get DefectDojo API token | `configure-stack.sh` step 2 | AWS SM `intelliops/dev/defectdojo → api_key` |
| Create ArgoCD CI token | `configure-stack.sh` step 3 | AWS SM `intelliops/dev/argocd → auth_token` |
| Set GitHub Actions secrets | `configure-stack.sh` step 6 | GitHub repo secrets via API |
| Build + push ECR stub images | `configure-stack.sh` step 0 | ECR bootstrap inline |
| Write INSTRUCTIONS.md | `configure-stack.sh` step 7 | File in repo root |
| Apply ArgoCD Applications | `configure-stack.sh` step 3 | `kubectl apply -f k8s/argocd/` |
| Fix Linkerd PKI cert expiry | `install-stack.sh` step 5 | Auto-detect + regenerate |
| Trigger ArgoCD initial sync | `configure-stack.sh` step 3 | ArgoCD API call |
| ExternalDNS Route53 records | `install-stack.sh` step 4 | Helm install + ExternalDNS |
| ACM certificate validation | Terraform | Route53 DNS validation auto-added |
| Kyverno admission policies | `install-stack.sh` step 10 | ArgoCD syncs from `k8s/kyverno-policies/` |

---

## Day-2 Operations — Automated

### Rotate GitHub Actions secrets

When ArgoCD token is near expiry (1-year lifetime) or SonarQube token needs refresh:

```bash
# Re-run configure-stack.sh — it regenerates tokens and pushes to GitHub
GITHUB_PAT=github_pat_xxx ./scripts/configure-stack.sh
```

The script is idempotent — safe to re-run at any time.

### Add a new service

```bash
# 1. Create ECR repo (Terraform)
cd terraform/environments/dev
terraform apply -target=module.ecr

# 2. Add manifests
cp k8s/apps/order-service.yaml k8s/apps/my-service.yaml
# Edit: name, image, env vars, service name

# 3. Commit and push — ArgoCD deploys automatically
git add k8s/apps/my-service.yaml
git commit -m "feat: add my-service deployment"
git push origin main
# ArgoCD picks up the new file and creates the Deployment within 3 minutes
```

### Rollback a deployment

```bash
# Git rollback — ArgoCD follows
git revert HEAD
git push origin main

# Or force-sync a specific revision
argocd app rollback microservices <revision-id>
```

### Scale services

Don't edit `replicas` — HPA manages that. To change HPA bounds:

```bash
# Edit the manifest
vim k8s/apps/my-service.yaml
# Change: minReplicas, maxReplicas, or targetCPUUtilizationPercentage

# Commit — ArgoCD applies the new HPA config
git add k8s/apps/my-service.yaml && git commit -m "ops: scale my-service HPA" && git push
```

---

## Full Platform from Scratch

```bash
# Prerequisites (one-time)
aws configure          # Set AWS credentials
git clone https://github.com/nabilpurkar/intelliops-sherlock.git
cd intelliops-sherlock

# Full install (~30 minutes)
GITHUB_PAT=github_pat_xxx ./scripts/install-stack.sh

# That's it. When it finishes:
# - EKS cluster running
# - All 18 ArgoCD apps Synced + Healthy
# - Grafana, ArgoCD, SonarQube, DefectDojo, Prometheus all accessible
# - GitHub Actions secrets set
# - INSTRUCTIONS.md written with all URLs and credentials
```

### What the GITHUB_PAT needs

A fine-grained PAT on the platform repo with:
- **Contents**: Read and write (for manifest updates from CI)
- **Secrets**: Read and write (for GitHub Actions secrets)
- **Variables**: Read and write (for AWS_ACCOUNT_ID, AWS_REGION)
- **Workflows**: Read and write (to trigger workflow_dispatch)

---

## What Still Requires Human Input

These steps cannot be automated because they require credentials or decisions only you can provide:

| Step | Why manual | How to do it |
|------|-----------|-------------|
| `aws configure` | AWS credentials are personal | `aws configure` or set `~/.aws/credentials` |
| GitHub PAT creation | PATs are per-user, GitHub web only | GitHub → Settings → Developer settings → PATs |
| Domain registration | Requires payment + ownership | Your registrar → point nameservers to Route53 |
| ACM certificate email validation | If DNS validation fails, email fallback | Check email for domain validation link |
| SonarQube Quality Gate customisation | Business decision (coverage thresholds) | SonarQube UI → Quality Gates |
| DefectDojo product ownership | Security team assignment | DefectDojo UI → Products → Assign owner |

---

## Verifying the Full Stack

After `install-stack.sh` completes, run this verification:

```bash
# 1. All ArgoCD apps Synced + Healthy
kubectl get applications -n argocd -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'

# 2. All pods running
kubectl get pods -A --no-headers | grep -vE 'Running|Completed|Succeeded' | wc -l
# Should be 0

# 3. All Prometheus targets up
curl -s https://prometheus.infrastructurepath.online/api/v1/targets | \
  python3 -c "import sys,json; t=json.load(sys.stdin)['data']['activeTargets']; down=[x for x in t if x['health']!='up']; print(f'{len(t)-len(down)}/{len(t)} targets UP, {len(down)} DOWN')"

# 4. GitHub Actions pipeline passing
# Push an empty commit to trigger CI
git commit --allow-empty -m "ci: verify pipeline post-install"
git push origin main
# Check: https://github.com/nabilpurkar/intelliops-sherlock/actions

# 5. Services reachable
curl https://apps.infrastructurepath.online/orders/health
curl https://apps.infrastructurepath.online/payments/health
curl https://apps.infrastructurepath.online/inventory/health

# 6. Traces flowing
# Make a request then check Tempo in Grafana → Explore → Tempo → Search
```

---

## Destroy — Full Teardown

```bash
./scripts/destroy-stack.sh
```

Handles:
- Removes ArgoCD Applications (triggers resource deletion in cluster)
- Removes ExternalSecret finalizers (prevents destroy hangs)
- Deletes Helm releases in dependency order
- Runs `terraform destroy` (removes EKS, VPC, ECR, IAM, Route53 records)

⚠️ This deletes everything including Route53 records and ACM certificates. DNS propagation after recreate takes ~5 minutes.

---

## Troubleshooting the Install

### install-stack.sh hung on a step

```bash
# Check which step it's on
cat .install-state

# Kill the script (Ctrl+C)
# Investigate the stuck step manually
kubectl get events -A --sort-by='.lastTimestamp' | tail -30

# Resume from that step
./scripts/install-stack.sh --from=<step>
```

### configure-stack.sh: "SonarQube admin credentials invalid"

```bash
# SonarQube may have reset its admin password after first login
# Get the current password from k8s secret
kubectl get secret sonarqube-sonarqube -n sonarqube -o jsonpath='{.data.sonarqube-password}' | base64 -d

# Update in AWS SM
aws secretsmanager put-secret-value \
  --secret-id intelliops/dev/sonarqube \
  --secret-string "{\"admin_password\":\"<password>\"}"

# Re-run
./scripts/configure-stack.sh --from=1
```

### configure-stack.sh: "DefectDojo API token failed"

```bash
# Get admin password from k8s secret (set by helm)
kubectl get secret defectdojo -n defectdojo -o jsonpath='{.data.DD_ADMIN_PASSWORD}' | base64 -d

# Re-run
./scripts/configure-stack.sh --from=2
```

### GitHub secrets not set (GITHUB_PAT error)

```bash
# Verify PAT has correct permissions
curl -sI -H "Authorization: token $GITHUB_PAT" \
  "https://api.github.com/repos/nabilpurkar/intelliops-sherlock/actions/secrets/public-key" | grep x-accepted

# Should show: x-accepted-github-permissions: secrets=write
# If secrets=read, update PAT permissions in GitHub → Settings → Developer settings

# Re-run just the secrets step
GITHUB_PAT=github_pat_xxx ./scripts/configure-stack.sh --from=6
```

---

## CI/CD Self-Service After Initial Setup

Once the stack is running, the CI/CD pipeline is fully self-service:

```
Developer workflow:
  1. git push to service repo
  2. CI runs: test → scan → build → sign → push → manifest update
  3. ArgoCD detects manifest change → deploys
  4. DAST runs against live app
  Total: ~8-12 minutes from push to production

Platform team workflow:
  1. Edit k8s/apps/*.yaml or k8s/argocd/platform/*.yaml
  2. git push
  3. ArgoCD deploys within 3 minutes
```

No manual `kubectl apply` or `helm install` needed for day-to-day operations.

---

## What's Next?

→ **[15-add-new-service.md](15-add-new-service.md)** — Add a new microservice end to end
→ **[16-helm-charts.md](16-helm-charts.md)** — Add a new platform component via Helm
→ **[13-troubleshooting.md](13-troubleshooting.md)** — When things go wrong
