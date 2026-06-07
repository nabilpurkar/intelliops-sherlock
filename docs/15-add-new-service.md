# Adding a New Service — End to End

> **What you'll learn:** How to add a brand-new microservice to this platform: write the service code, containerise it, wire it into CI/CD, secure it with Kyverno + secrets management, connect it to observability (metrics, logs, traces), and deploy it with ArgoCD — from zero to production in one workflow.

---

## Overview

Adding a service has six layers. Each layer builds on the previous one.

```
Layer 1: Service code + Dockerfile
Layer 2: Terraform — ECR repository + IAM
Layer 3: Kubernetes manifests — Deployment, Service, HPA, ServiceMonitor
Layer 4: CI/CD pipeline — build, scan, sign, deploy
Layer 5: Security — secrets, Kyverno, image signing
Layer 6: Observability — metrics, logs, distributed traces
```

The whole process takes about 30 minutes the first time; 10 minutes for subsequent services.

---

## Layer 1: Service Code

### Directory structure

Create the service directory following the existing convention:

```
services/
└── my-service/
    ├── Dockerfile
    ├── main.py
    ├── requirements.txt
    ├── requirements-test.txt
    ├── pytest.ini
    └── tests/
        ├── conftest.py
        └── test_main.py
```

### main.py — FastAPI with OTEL built in

Every service must initialise OpenTelemetry at startup. Copy this template exactly — the `_init_otel()` call at module level ensures traces flow to Tempo before any request arrives.

```python
from __future__ import annotations
import os

# ── OTEL initialisation — must be before FastAPI import ─────────────────────
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource, SERVICE_NAME
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

def _init_otel() -> None:
    if os.getenv("OTEL_SDK_DISABLED", "").lower() == "true":
        return
    resource = Resource.create({SERVICE_NAME: os.getenv("OTEL_SERVICE_NAME", "my-service")})
    provider = TracerProvider(resource=resource)
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(provider)

_init_otel()
# ─────────────────────────────────────────────────────────────────────────────

from fastapi import FastAPI
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from starlette.responses import Response

app = FastAPI(title="my-service", version="1.0.0")
FastAPIInstrumentor.instrument_app(app)   # auto-traces all routes

# Prometheus custom metrics
REQUEST_COUNT = Counter("my_service_requests_total", "Total requests", ["method", "endpoint", "status"])
REQUEST_DURATION = Histogram("my_service_request_duration_seconds", "Request duration")

@app.get("/health")
def health():
    return {"status": "ok", "service": "my-service"}

@app.get("/ready")
def ready():
    return {"status": "ready"}

@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

# Add your business logic routes here
```

### requirements.txt

```
fastapi>=0.100.0
uvicorn>=0.20.0
prometheus-client>=0.17.0
opentelemetry-sdk>=1.27.0
opentelemetry-exporter-otlp-proto-http>=1.27.0
opentelemetry-instrumentation-fastapi>=0.48b0
# Add httpx + instrumentation-httpx if your service calls other services
```

### requirements-test.txt

```
pytest>=7.0.0
pytest-cov>=4.0.0
httpx>=0.25.0
```

### tests/conftest.py

**Critical:** This must be the first file pytest loads. It disables OTEL before `main.py` imports so tests don't send traces to the collector.

```python
import os
os.environ.setdefault("OTEL_SDK_DISABLED", "true")
```

### tests/test_main.py

```python
from fastapi.testclient import TestClient
from main import app

client = TestClient(app)

def test_health():
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"

def test_ready():
    r = client.get("/ready")
    assert r.status_code == 200

def test_metrics():
    r = client.get("/metrics")
    assert r.status_code == 200
    assert b"my_service_requests_total" in r.content
```

### pytest.ini

```ini
[pytest]
testpaths = tests
python_files = test_*.py
```

### Dockerfile

```dockerfile
FROM python:3.12-slim
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
RUN useradd -u 1000 -m app
USER 1000
WORKDIR /app
COPY main.py .
EXPOSE 8000
CMD ["python3", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

**Rules enforced by Hadolint + Kyverno:**
- `USER 1000` — never root
- No `:latest` in `FROM` — pin to `-slim`
- `EXPOSE 8000` — document the port
- `COPY` not `ADD` for local files

---

## Layer 2: Terraform — ECR + IAM

Add the ECR repository to Terraform so it exists before the CI pipeline tries to push.

Edit `terraform/environments/dev/main.tf` (or wherever the ECR module is called):

```hcl
# Add to the existing ecr module block
module "ecr" {
  source = "../../modules/ecr"
  # ...existing services...
  services = [
    "order-service",
    "payment-service",
    "inventory-service",
    "my-service",       # ← add here
  ]
}
```

Then apply:

```bash
cd terraform/environments/dev
terraform plan -out=tfplan
terraform apply tfplan
```

This creates:
- ECR repository: `007066145518.dkr.ecr.us-east-1.amazonaws.com/intelliops-dev/my-service`
- Repository policy allowing the GitHub Actions OIDC role to push images
- Lifecycle policy: keep last 10 tagged images, delete untagged after 1 day

---

## Layer 3: Kubernetes Manifests

Create `k8s/apps/my-service.yaml`. Use this template — every field is required by Kyverno policies:

```yaml
# k8s/apps/my-service.yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-service
  namespace: apps
  labels:
    app: my-service
    team: platform
spec:
  replicas: 2
  selector:
    matchLabels:
      app: my-service
  template:
    metadata:
      labels:
        app: my-service
        team: platform
    spec:
      serviceAccountName: apps-sa
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
      containers:
        - name: my-service
          image: 007066145518.dkr.ecr.us-east-1.amazonaws.com/intelliops-dev/my-service:v1.0.0
          ports:
            - containerPort: 8000
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 1000
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
          env:
            - name: OTEL_SERVICE_NAME
              value: "my-service"
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              valueFrom:
                configMapKeyRef:
                  name: apps-config
                  key: OTEL_EXPORTER_OTLP_ENDPOINT
            - name: OTEL_EXPORTER_OTLP_PROTOCOL
              value: "http/protobuf"
            - name: OTEL_TRACES_EXPORTER
              value: "otlp"
            # Secret references — never hardcode values
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: my-service-secrets
                  key: database_url
          livenessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 10
            periodSeconds: 30
          readinessProbe:
            httpGet:
              path: /ready
              port: 8000
            initialDelaySeconds: 5
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: my-service
  namespace: apps
  labels:
    app: my-service
spec:
  selector:
    app: my-service
  ports:
    - port: 8000
      targetPort: 8000
      name: http
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-service
  namespace: apps
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-service
  minReplicas: 2
  maxReplicas: 4
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: my-service
  namespace: apps
  labels:
    app: my-service
spec:
  selector:
    matchLabels:
      app: my-service
  endpoints:
    - port: http
      path: /metrics
      interval: 15s
```

### Secrets via ExternalSecrets

Never put secret values in YAML. Use ExternalSecrets to pull from AWS Secrets Manager:

```yaml
# k8s/apps/my-service-secrets.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: my-service-secrets
  namespace: apps
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: my-service-secrets          # k8s Secret name pods reference
    creationPolicy: Owner
  data:
    - secretKey: database_url          # key in the k8s Secret
      remoteRef:
        key: intelliops/dev/my-service # AWS SM secret path
        property: database_url         # key within that JSON secret
```

Store the actual value in AWS SM:

```bash
aws secretsmanager create-secret \
  --name intelliops/dev/my-service \
  --secret-string '{"database_url":"postgresql://user:pass@host:5432/db"}' \
  --region us-east-1
```

---

## Layer 4: CI/CD Pipeline

The platform CI pipeline (`ci.yml`) runs automatically on every push. For a new service, you also need CI in the **service's own repo** that handles build, image scan, and deployment.

### Service repo CI pipeline

In the service repository (e.g., `github.com/nabilpurkar/my-service`), create `.github/workflows/ci.yml`:

```yaml
name: CI — my-service

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:

permissions:
  id-token: write
  contents: read
  security-events: write

jobs:

  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
          cache: pip
      - run: pip install -r requirements.txt -r requirements-test.txt pytest-cov
      - run: pytest tests/ -v --cov=. --cov-report=xml:coverage.xml

  build-push:
    needs: [test]
    if: github.ref == 'refs/heads/main'
    uses: nabilpurkar/intelliops-sherlock/.github/workflows/_docker-build-push.yml@main
    with:
      service: my-service
      aws_account_id: ${{ vars.AWS_ACCOUNT_ID }}
      role_arn: ${{ vars.ROLE_ARN }}
      image_tag: ${{ github.sha }}
    secrets:
      defectdojo_api_key: ${{ secrets.DEFECTDOJO_API_KEY }}

  deploy:
    needs: [build-push]
    runs-on: ubuntu-latest
    steps:
      - name: Trigger manifest update in platform repo
        uses: peter-evans/repository-dispatch@v3
        with:
          token: ${{ secrets.PLATFORM_REPO_TOKEN }}
          repository: nabilpurkar/intelliops-sherlock
          event-type: manifest-update
          client-payload: |
            {
              "service": "my-service",
              "image_tag": "${{ github.sha }}",
              "actor": "${{ github.actor }}",
              "aws_account_id": "${{ vars.AWS_ACCOUNT_ID }}",
              "aws_region": "us-east-1"
            }
```

### Secrets required in service repo

| Secret | Value | How to get |
|--------|-------|-----------|
| `PLATFORM_REPO_TOKEN` | Fine-grained PAT with `contents:write` on platform repo | GitHub → Settings → PATs |
| `DEFECTDOJO_API_KEY` | From AWS SM `intelliops/dev/defectdojo` → `api_key` | `./scripts/configure-stack.sh` |
| `AWS_ACCOUNT_ID` (var) | `007066145518` | `aws sts get-caller-identity` |
| `ROLE_ARN` (var) | IAM role for OIDC push | Terraform output `github_actions_role_arn` |

---

## Layer 5: Security

### Kyverno — what runs automatically

All policies in `k8s/kyverno-policies/` apply to the `apps` namespace automatically. Your service must comply:

| Policy | Requirement | How to comply |
|--------|-------------|---------------|
| `disallow-privileged.yaml` | No privileged containers | `securityContext.allowPrivilegeEscalation: false` |
| `disallow-latest-tag.yaml` | No `:latest` image tag | Pin to SHA or semver in manifest |
| `require-resource-limits.yaml` | CPU + memory limits | Set in `resources.limits` |
| `restrict-image-registries.yaml` | ECR only | Use `007066145518.dkr.ecr.us-east-1.amazonaws.com` prefix |

Check compliance before pushing:

```bash
# Test your manifest against Kyverno policies locally
kubectl apply --dry-run=server -f k8s/apps/my-service.yaml
# If Kyverno rejects it, you'll see the admission error here
```

### Image signing — automatic via CI

The `_docker-build-push.yml` workflow automatically signs images with Cosign keyless signing. No action needed. To verify a signed image:

```bash
cosign verify \
  007066145518.dkr.ecr.us-east-1.amazonaws.com/intelliops-dev/my-service:abc1234 \
  --certificate-identity-regexp="https://github.com/nabilpurkar/my-service" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com"
```

### Secret rotation

When you need to rotate a secret (e.g., database password):

```bash
# 1. Update in AWS SM
aws secretsmanager put-secret-value \
  --secret-id intelliops/dev/my-service \
  --secret-string '{"database_url":"postgresql://user:newpass@host:5432/db"}'

# 2. Trigger ExternalSecret refresh (pulls new value within 1 hour, or force now)
kubectl annotate externalsecret my-service-secrets -n apps \
  force-sync=$(date +%s) --overwrite

# 3. Restart pods to pick up new secret
kubectl rollout restart deployment/my-service -n apps
```

---

## Layer 6: Observability

### Metrics — automatic

The `ServiceMonitor` you created in Layer 3 tells Prometheus to scrape `/metrics` every 15 seconds. Your custom `prometheus_client` counters and histograms appear automatically in Grafana.

Find them at: `Grafana → Explore → Prometheus → metric name starts with `my_service_`

### Logs — automatic

All stdout/stderr from pods is collected by Promtail and indexed in Loki. No configuration needed.

Query in Grafana:
```logql
{namespace="apps", app="my-service"} |= "ERROR"
```

### Traces — automatic via OTEL in main.py

The `_init_otel()` function in your `main.py` registers a `TracerProvider` that sends traces via OTLP HTTP to the collector at `http://otel-collector.monitoring.svc.cluster.local:4318`. Traces appear in Grafana → Tempo within seconds.

The `OTEL_EXPORTER_OTLP_ENDPOINT` is read from the `apps-config` ConfigMap — already set to the correct collector address. No changes needed.

To add a custom span inside a route:

```python
tracer = trace.get_tracer("my-service")

@app.post("/orders")
def create_order(payload: dict):
    with tracer.start_as_current_span("validate-order") as span:
        span.set_attribute("order.id", payload.get("id"))
        # ... validation logic
```

### Grafana dashboard (optional)

Create a ConfigMap in `k8s/grafana/dashboard-my-service.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: dashboard-my-service
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
    grafana_folder: "Services"
data:
  my-service.json: |
    {
      "title": "my-service",
      "panels": [...]
    }
```

ArgoCD will deploy it; Grafana's sidecar picks it up within 30 seconds.

---

## Checklist: New Service Go-Live

```
Code
  [ ] main.py has _init_otel() with OTEL_SDK_DISABLED guard
  [ ] /health, /ready, /metrics endpoints exist
  [ ] tests/conftest.py sets OTEL_SDK_DISABLED=true
  [ ] Unit tests cover happy path + error cases

Container
  [ ] Dockerfile: USER 1000, no :latest in FROM, EXPOSE 8000
  [ ] Runs on port 8000 (all services standardised)

Terraform
  [ ] ECR repository created (terraform apply)

K8s manifests
  [ ] Deployment: runAsNonRoot, readOnlyRootFilesystem, resource limits
  [ ] Service: port 8000
  [ ] HPA: min=2 max=4
  [ ] ServiceMonitor: scrapes /metrics
  [ ] ExternalSecret: references AWS SM path (no literal values)

Secrets
  [ ] Secret values stored in AWS SM under intelliops/dev/<service>
  [ ] ExternalSecret synced: kubectl get externalsecret -n apps

CI/CD
  [ ] Service repo has .github/workflows/ci.yml
  [ ] PLATFORM_REPO_TOKEN + DEFECTDOJO_API_KEY set in service repo secrets
  [ ] AWS_ACCOUNT_ID + ROLE_ARN set as repo variables

Security
  [ ] kubectl apply --dry-run=server passes (Kyverno admission)
  [ ] Image signed by Cosign after first CI push

Observability
  [ ] kubectl get servicemonitor my-service -n apps → Synced
  [ ] Prometheus target appears: prometheus.yourdomain.com/targets
  [ ] Traces visible in Grafana → Tempo after first request
```

---

## Adding Kong Ingress

To expose the service externally via Kong:

```yaml
# Add to k8s/ingress/ingress-apps.yaml
- host: apps.infrastructurepath.online
  http:
    paths:
      - path: /my-service
        pathType: Prefix
        backend:
          service:
            name: my-service
            port:
              number: 8000
```

Add the annotation to the ingress metadata:
```yaml
annotations:
  konghq.com/strip-path: "false"   # Keep /my-service prefix when forwarding
```

Test after Kong reconciles (~30s):
```bash
curl https://apps.infrastructurepath.online/my-service/health
# {"status": "ok", "service": "my-service"}
```

---

## What's Next?

→ **[16-helm-charts.md](16-helm-charts.md)** — Adding a new platform component via Helm
→ **[17-one-click-automation.md](17-one-click-automation.md)** — Automating the entire workflow
→ **[08-security-compliance.md](08-security-compliance.md)** — Kyverno policies in depth
