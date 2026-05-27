# IntelliOps Sherlock — Deploy / Destroy Runbook

Full lifecycle: `terraform apply` → `install-stack.sh` → `configure-stack.sh` → verify AIOps → `destroy-stack.sh` → `terraform destroy`.

---

## 0. Prerequisites (one-time or per fresh deploy)

### 0a. Seed ALL AWS Secrets Manager secrets BEFORE running install-stack.sh

Terraform creates the SM secret containers with **no values**. ExternalSecrets Operator (ESO) will show `SecretSyncedError` for every ExternalSecret, and pods that mount those k8s Secrets will fail to start. Helm `--wait` then times out.

Run this block immediately after `terraform apply` completes:

```bash
# Generate strong passwords
PG_PASS=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)
SQ_PASS=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)
KG_PASS=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)
DJ_PASS=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)
DJ_SK=$(openssl rand -base64 32)
DJ_AES=$(openssl rand -base64 32 | head -c 32)
DJ_METRICS=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20)
DJ_VALKEY=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)
ARGO_PASS=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)
GRAF_PASS=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)

aws secretsmanager put-secret-value --region us-east-1 \
  --secret-id intelliops/dev/postgresql \
  --secret-string "{\"postgres_password\":\"${PG_PASS}\",\"sonarqube_password\":\"${SQ_PASS}\",\"kong_password\":\"${KG_PASS}\",\"defectdojo_password\":\"${DJ_PASS}\"}"

aws secretsmanager put-secret-value --region us-east-1 \
  --secret-id intelliops/dev/defectdojo \
  --secret-string "{\"admin_password\":\"${DJ_PASS}\",\"secret_key\":\"${DJ_SK}\",\"credential_aes256_key\":\"${DJ_AES}\",\"metrics_http_auth_password\":\"${DJ_METRICS}\",\"valkey_password\":\"${DJ_VALKEY}\"}"

aws secretsmanager put-secret-value --region us-east-1 \
  --secret-id intelliops/dev/argocd \
  --secret-string "{\"admin_password\":\"${ARGO_PASS}\"}"

aws secretsmanager put-secret-value --region us-east-1 \
  --secret-id intelliops/dev/grafana \
  --secret-string "{\"admin_password\":\"${GRAF_PASS}\"}"

# SonarQube MUST use "admin" — configure-stack.sh logs in with this and then rotates it
aws secretsmanager put-secret-value --region us-east-1 \
  --secret-id intelliops/dev/sonarqube \
  --secret-string '{"admin_password":"admin"}'

# Backstage — placeholder until real GitHub token is available
aws secretsmanager put-secret-value --region us-east-1 \
  --secret-id intelliops/dev/backstage \
  --secret-string '{"github_token":"ghp_placeholder_replace_with_real_token"}'

# Slack — placeholder; replace with real webhook for AIOps alerts
aws secretsmanager put-secret-value --region us-east-1 \
  --secret-id intelliops/dev/slack \
  --secret-string '{"webhook_url":"https://hooks.slack.com/services/placeholder"}'

# Falco → DefectDojo API key (placeholder; update after DefectDojo login)
aws secretsmanager put-secret-value --region us-east-1 \
  --secret-id intelliops/dev/falco-defectdojo \
  --secret-string '{"api_key":"placeholder-update-after-login"}'
```

After seeding, force ESO to resync all ExternalSecrets:
```bash
kubectl annotate externalsecret -A --all force-sync=$(date +%s) --overwrite
```

### 0b. Generate Linkerd PKI and update helm values

The SM secret `intelliops/dev/linkerd` is recreated empty on each `terraform apply` (recovery_window=0). Must regenerate each time.

```bash
# 1. Generate trust anchor (10yr) and issuer cert (1yr)
step certificate create root.linkerd.cluster.local ca.crt ca.key \
  --profile root-ca --no-password --insecure \
  --not-after 87600h

step certificate create identity.linkerd.cluster.local issuer.crt issuer.key \
  --profile intermediate-ca --no-password --insecure \
  --ca ca.crt --ca-key ca.key --not-after 8760h

# 2. Store in SM
aws secretsmanager put-secret-value --region us-east-1 \
  --secret-id intelliops/dev/linkerd \
  --secret-string "{
    \"ca_crt_b64\":\"$(base64 -w0 ca.crt)\",
    \"issuer_crt_b64\":\"$(base64 -w0 issuer.crt)\",
    \"issuer_key_b64\":\"$(base64 -w0 issuer.key)\"
  }"

# 3. Update k8s/helm-values/linkerd-control-plane-values.yaml
#    Replace identityTrustAnchorsPEM with the new ca.crt content
#    (The install script reads the issuer cert/key from SM at step 9b)
cat ca.crt   # paste into linkerd-control-plane-values.yaml → identityTrustAnchorsPEM

# 4. Clean up
rm -f ca.crt ca.key issuer.crt issuer.key
```

Update the comment in the values file:
```yaml
# Trust anchor valid until: <date+10yr>  |  Issuer valid until: <date+1yr>
```

### 0c. AIOps ECR images

The `intelliops-aiops` repo CI builds and pushes images to ECR. If CI hasn't run (first deploy or new AWS account), push stub images manually so pods can start:

```bash
cat > /tmp/stub/server.py << 'EOF'
from http.server import HTTPServer, BaseHTTPRequestHandler
import json, os

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"status":"ok","service":os.getenv("SERVICE_NAME","aiops")}).encode())
    def log_message(self, fmt, *args): pass

HTTPServer(("0.0.0.0", 8080), H).serve_forever()
EOF

cat > /tmp/stub/train.py << 'EOF'
print("Training complete (stub)")
EOF

cat > /tmp/stub/Dockerfile << 'EOF'
FROM python:3.11-slim
WORKDIR /app
COPY server.py train.py ./
CMD ["python", "server.py"]
EOF

REGISTRY="$(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-east-1.amazonaws.com"
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "$REGISTRY"

docker build -t aiops-stub:latest /tmp/stub/
for svc in anomaly-detector forecaster alert-correlator ai-agent; do
  docker tag aiops-stub:latest "${REGISTRY}/intelliops-dev/${svc}:latest"
  docker push "${REGISTRY}/intelliops-dev/${svc}:latest"
done
```

---

## 1. Terraform Apply

```bash
cd terraform/environments/dev
terraform init
terraform apply -auto-approve
```

Takes ~15 min. Creates EKS cluster `intelliops-dev`, VPC, IAM/IRSA roles, ECR repos, SQS queue, SM secret containers (empty).

---

## 2. Install Stack

```bash
cd /home/ec2-user/intelliops-sherlock
bash scripts/install-stack.sh 2>&1 | tee /tmp/install.log
```

**Must complete step 0 (SM seeding + Linkerd PKI) first.**

### Known issues fixed in helm values

| Chart | Bug | Fix applied |
|-------|-----|-------------|
| `opencost/opencost` | Prometheus URL key was `opencost.exporter.prometheus` — chart template reads `opencost.prometheus` | Fixed in `opencost-values.yaml` |
| `litmuschaos/litmus` | MongoDB PVC has no StorageClass → `Pending` forever | Fixed: `mongodb.persistence.storageClass: gp2` in `litmus-values.yaml` |
| `litmuschaos/litmus` | `adminConfig.DB_SERVER: "mongo-service"` → mongosh treats it as DB name, connects to localhost | Fixed: removed override, chart template generates correct replica-set URI |
| `litmuschaos/litmus` | Default `mongodb.replicaCount: 3` exhausts cluster resources | Fixed: `mongodb.replicaCount: 1` |
| locust (ArgoCD app) | HTTP liveness probe on port 8089 kills headless locust container (~90s after start) | Fixed: patch deployment to remove liveness/readiness probes after ArgoCD sync |

### If install-stack.sh exits early (set -euo pipefail)

Identify the failed step in the log, fix the root cause, then re-run — the script is idempotent (`helm status` skips already-installed releases).

---

## 3. Configure Stack

```bash
bash scripts/configure-stack.sh 2>&1 | tee /tmp/configure.log
```

**SonarQube note**: `intelliops/dev/sonarqube → admin_password` must be `"admin"` on first run. configure-stack.sh validates login, creates the project, generates a CI token, then updates the SM secret with the token. Do NOT pre-rotate the SonarQube admin password before running configure.

---

## 4. Verify AIOps

```bash
kubectl get pods -n aiops-demo
# Expected: ai-agent, anomaly-detector, forecaster, alert-correlator all 1/1 Running
```

If pods are in `ImagePullBackOff` → ECR images are missing (see step 0c).

If `ai-agent` has `CreateContainerConfigError` → `slack-webhook` k8s Secret missing → seed `intelliops/dev/slack` in SM and force ESO resync.

---

## 5. Resource Contention (HPA + Locust)

Locust runs load tests against microservices. With a small cluster (4× `m5.xlarge`, 2 vCPU each), HPAs scale microservices beyond available CPU:

- Symptoms: pods in `Pending` with `Insufficient cpu` or topology spread violations
- Fix before `configure-stack.sh`:

```bash
# Pause load generation
kubectl scale deployment locust -n locust --replicas=0

# Cap HPAs
kubectl patch hpa order-service-hpa     -n apps --type=merge -p='{"spec":{"maxReplicas":3}}'
kubectl patch hpa payment-service-hpa   -n apps --type=merge -p='{"spec":{"maxReplicas":3}}'
kubectl patch hpa inventory-service-hpa -n apps --type=merge -p='{"spec":{"maxReplicas":3}}'

# Scale down immediately (don't wait for HPA)
kubectl scale deployment order-service payment-service inventory-service -n apps --replicas=2
```

Topology spread constraint violations (pod can't schedule on the one node that satisfies spread but has no CPU):
```bash
kubectl patch deployment <service> -n apps --type=json \
  -p='[{"op":"remove","path":"/spec/template/spec/topologySpreadConstraints"}]'
```

---

## 6. Destroy Stack

```bash
SKIP_CONFIRM=true bash scripts/destroy-stack.sh 2>&1 | tee /tmp/destroy.log
```

### ExternalSecret finalizers block namespace deletion

ESO adds `externalsecrets.external-secrets.io/externalsecret-cleanup` finalizer to every ExternalSecret. When ESO is uninstalled first (before namespaces are deleted), these finalizers can never be removed by the controller — namespaces get stuck in `Terminating`.

The destroy script has force-removal logic, but if it gets stuck, run manually:

```bash
# Clear all ExternalSecret finalizers across all namespaces
for ns in $(kubectl get ns -o name 2>/dev/null | cut -d/ -f2); do
  for es in $(kubectl get externalsecrets -n "$ns" -o name 2>/dev/null); do
    kubectl patch "$es" -n "$ns" --type=json \
      -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
  done
done
```

Run this proactively while destroy is deleting namespaces — it's safe to run at any time.

### Terraform destroy (after destroy-stack.sh)

destroy-stack.sh calls `terraform destroy` automatically (step 6/8). If it fails or was skipped:

```bash
cd terraform/environments/dev
terraform destroy -auto-approve
```

Takes ~10–15 min. EKS node group deletion is the slowest part.

---

## 7. Commit Changed Files

After each full lifecycle run, these files may have been changed and should be committed:

- `k8s/helm-values/linkerd-control-plane-values.yaml` — new trust anchor PEM + expiry dates
- `k8s/helm-values/opencost-values.yaml` — Prometheus URL key fix (already fixed, should not change again)
- `k8s/helm-values/litmus-values.yaml` — MongoDB storageClass + replicaCount (already fixed)

---

## 8. Secrets Reference

| SM Secret | Keys | Notes |
|-----------|------|-------|
| `intelliops/dev/postgresql` | `postgres_password`, `sonarqube_password`, `kong_password`, `defectdojo_password` | Used by ESO for DB init |
| `intelliops/dev/defectdojo` | `admin_password`, `secret_key`, `credential_aes256_key`, `metrics_http_auth_password`, `valkey_password` | |
| `intelliops/dev/argocd` | `admin_password` | |
| `intelliops/dev/grafana` | `admin_password` | |
| `intelliops/dev/sonarqube` | `admin_password` | Must be `"admin"` before configure-stack.sh |
| `intelliops/dev/linkerd` | `ca_crt_b64`, `issuer_crt_b64`, `issuer_key_b64` | Regenerate after every `terraform apply` |
| `intelliops/dev/backstage` | `github_token` | Real PAT needed for GitHub integration |
| `intelliops/dev/slack` | `webhook_url` | Real webhook for AIOps alerts |
| `intelliops/dev/falco-defectdojo` | `api_key` | Update after DefectDojo first login |

All secrets survive `destroy-stack.sh` (only SM containers Terraform manages are deleted on `terraform destroy`).
