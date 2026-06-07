# IntelliOps Sherlock 🔍

> **One-click AIOps + DevSecOps + FinOps platform on AWS** — from `git clone` to a production-grade Kubernetes environment with AI auto-remediation, full observability, multi-layer security, and cost monitoring.

---

## What Is This?

IntelliOps Sherlock is a **complete, real-world DevSecOps learning platform** built on AWS EKS. Deploy it once with three shell commands and get a fully instrumented environment with 25+ enterprise tools running together — the same stack you'd find at a fintech, bank, or large SaaS company.

**Who is it for?** DevOps engineers, SREs, platform engineers, and developers who want hands-on experience with the full modern cloud-native toolchain — not tools in isolation, but how they all work together.

**Why does it exist?** Most tutorials teach one tool at a time. Real production systems need ALL of them to work together. This project shows exactly how: ArgoCD pulls from Git, Kyverno blocks insecure deployments, OTEL collector forwards traces to Tempo, Prometheus fires SLO burn-rate alerts, and Claude Sonnet reads the alerts and patches the deployment — automatically.

---

## What You Will Build

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         IntelliOps Sherlock                                  │
│                                                                               │
│  Developer  →  GitHub CI (11 stages)  →  ECR  →  ArgoCD  →  EKS Cluster   │
│                                                                               │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                        AWS EKS Cluster                                │   │
│  │                                                                        │   │
│  │  ┌─────────────┐  ┌─────────────────┐  ┌──────────────────────────┐ │   │
│  │  │  apps ns    │  │  monitoring ns   │  │  security ns             │ │   │
│  │  │─────────────│  │─────────────────│  │──────────────────────────│ │   │
│  │  │ order-svc   │  │ Prometheus       │  │ Kyverno (7 policies)     │ │   │
│  │  │ payment-svc │◄─┤ Grafana (8 dash)│  │ Falco (runtime threats)  │ │   │
│  │  │ inventory   │  │ Loki (logs)     │  │ cert-manager (TLS)       │ │   │
│  │  │             │  │ Tempo (traces)  │  │ Linkerd (mTLS mesh)      │ │   │
│  │  │ OTEL auto-  │  │ OTEL Collector  │  │ OPA/Gatekeeper           │ │   │
│  │  │ instrument  │  └─────────────────┘  └──────────────────────────┘ │   │
│  │  └──────┬──────┘                                                     │   │
│  │         │                                                              │   │
│  │  ┌──────▼──────────────────────────────────────────────────────────┐ │   │
│  │  │  Kong API Gateway  ──►  AWS ALB  ──►  Route53  ──►  *.domain   │ │   │
│  │  └─────────────────────────────────────────────────────────────────┘ │   │
│  │                                                                        │   │
│  │  ┌────────────────────────┐   ┌────────────────────────────────────┐ │   │
│  │  │  aiops-demo ns          │   │  tools ns                          │ │   │
│  │  │────────────────────────│   │────────────────────────────────────│ │   │
│  │  │ AI Agent (Claude 3.5)  │   │ ArgoCD   SonarQube   DefectDojo    │ │   │
│  │  │ Anomaly Detector (ML)  │◄──┤ Backstage  LitmusChaos  OpenCost  │ │   │
│  │  │ Alert Correlator       │   │ Prometheus Pushgateway             │ │   │
│  │  │ Forecaster             │   └────────────────────────────────────┘ │   │
│  │  └────────────┬───────────┘                                           │   │
│  └───────────────┼────────────────────────────────────────────────────────┘  │
│                  │                                                             │
│            AWS Bedrock (Claude Sonnet 3.5)  ◄──  SQS anomaly queue          │
└─────────────────────────────────────────────────────────────────────────────┘

  Terraform manages: VPC · EKS · ECR (8 repos) · IAM/IRSA · Secrets Manager · SQS
```

---

## What You Will Learn (25 Skills)

After completing this project, you can confidently say in any interview:

- [ ] Deploy and manage an **EKS cluster** with Terraform (IaC end-to-end)
- [ ] Build a **multi-stage CI/CD pipeline** with 11 security gates
- [ ] Implement **GitOps** with ArgoCD (declarative, self-healing deployments)
- [ ] Enforce **pod security policies** with Kyverno (PCI-DSS/RBI-level controls)
- [ ] Sign container images with **Cosign** and verify signatures at admission
- [ ] Configure **OTEL auto-instrumentation** — traces without changing application code
- [ ] Build **Grafana dashboards** for SLOs, DORA metrics, cost, and compliance
- [ ] Implement **SLOs with error budgets** and multi-window burn-rate alerts
- [ ] Configure **Loki + Promtail** for structured log aggregation
- [ ] Deploy **Tempo** for distributed tracing and correlate traces ↔ logs
- [ ] Manage secrets with **External Secrets Operator** + AWS Secrets Manager
- [ ] Implement **mTLS service mesh** with Linkerd
- [ ] Set up **runtime security** with Falco (kernel-level threat detection)
- [ ] Deploy a **Kong API Gateway** with Route53 + ACM TLS termination
- [ ] Run **SAST, SCA, DAST** scanning automated in CI/CD
- [ ] Build an **AIOps pipeline** with AWS Bedrock Claude for auto-remediation
- [ ] Configure **ML-based anomaly detection** on Prometheus metrics
- [ ] Monitor **Kubernetes costs** with OpenCost and FinOps dashboards
- [ ] Run **chaos engineering experiments** with LitmusChaos
- [ ] Publish a **Backstage developer portal** with service catalog
- [ ] Configure **IRSA** (IAM Roles for Service Accounts) for pod-level AWS auth
- [ ] Write **OPA/Conftest policies** for IaC security validation in CI
- [ ] Set up **HPA** (Horizontal Pod Autoscaler) based on CPU and memory metrics
- [ ] Configure **Prometheus ServiceMonitors** for custom application metrics
- [ ] Write **PrometheusRule** resources for SLO recording rules and alerts

---

## Requirements

| Component | Requirement | Notes |
|-----------|------------|-------|
| **AWS Account** | Admin IAM role or user | Terraform creates ~40 resources |
| **EC2 Instance** | t3.large (8GB RAM), Amazon Linux 2023 | Used as deployment machine |
| **IAM Role** | Attached to EC2: EKS, ECR, SM, S3, Route53 | No access keys needed |
| **Domain** | Route53 hosted zone (e.g. yourname.online) | ~$1/year .online domains |
| **ACM Certificate** | Wildcard *.yourdomain.com in us-east-1 | Free via ACM |
| **S3 Bucket** | For Terraform state (e.g. intelliops-tfstate-yourname) | Remote state locking |
| **Time** | ~60 minutes first run | 15 min TF + 30 min install + 15 min configure |

---

## One-Click Setup (5 Commands)

```bash
# 1. Clone the repo
git clone https://github.com/nabilpurkar/intelliops-sherlock && cd intelliops-sherlock

# 2. Create all AWS infrastructure (~15 min)
cd terraform/environments/dev && terraform init && terraform apply -auto-approve && cd ../../..

# 3. Install all 28 platform components (~30 min, auto-resumes if interrupted)
./scripts/install-stack.sh

# 4. Configure tools post-install (ArgoCD, SonarQube, DefectDojo tokens)
GITHUB_PAT=ghp_yourtoken ./scripts/configure-stack.sh

# 5. Get all credentials and URLs
cat INSTRUCTIONS.md
```

> **Interrupted?** Re-run `./scripts/install-stack.sh` — it resumes from the last checkpoint automatically.
> **Start fresh?** `./scripts/install-stack.sh --reset`
> **Background destroy when done:** `./scripts/destroy-stack.sh --bg`

---

## All UIs You Get Access To

| Service | URL | Purpose |
|---------|-----|---------|
| **Grafana** | https://grafana.yourdomain.com | Dashboards, metrics, traces, logs |
| **ArgoCD** | https://argocd.yourdomain.com | GitOps deployments |
| **Prometheus** | https://prometheus.yourdomain.com | Metrics query + alert rules |
| **AlertManager** | https://alertmanager.yourdomain.com | Alert routing + silences |
| **SonarQube** | https://sonarqube.yourdomain.com | Code quality, security hotspots |
| **DefectDojo** | https://defectdojo.yourdomain.com | Security findings from all scans |
| **Backstage** | https://backstage.yourdomain.com | Developer portal + service catalog |
| **Kong Admin** | https://kong-admin.yourdomain.com | API gateway management |
| **Locust** | https://locust.yourdomain.com | Load testing |
| **Apps** | https://apps.yourdomain.com | /orders, /payments, /inventory APIs |

*All credentials are in `INSTRUCTIONS.md` after configure-stack.sh completes.*

---

## Cost (us-east-1, On-Demand Pricing)

| Component | $/hour | $/day | $/month |
|-----------|--------|-------|---------|
| EKS Control Plane | $0.100 | $2.40 | $73 |
| 4× t3.large nodes | $0.333 | $8.00 | $240 |
| NAT Gateway | $0.045 | $1.08 | $33 |
| ALB (1 LCU avg) | $0.016 | $0.38 | $12 |
| EBS (4× 20GB gp3) | $0.003 | $0.07 | $2 |
| **Total (running)** | **~$0.50** | **~$12** | **~$360** |
| **After destroy** | **$0** | **$0** | **$0** |

> **💡 For a 4-hour learning session:** ~$2 total. Destroy completely when done.
> **💡 For a day of learning:** ~$12. Everything is recreatable from `terraform apply`.

---

## Complete Tech Stack

### Infrastructure
`Terraform 1.10` · `AWS EKS 1.35` · `AWS ECR` · `AWS Secrets Manager` · `AWS SQS` · `AWS Bedrock` · `VPC + NAT Gateway` · `Route53` · `ACM` · `ALB`

### CI/CD & GitOps
`GitHub Actions (11 workflows)` · `ArgoCD 2.x` · `Cosign (image signing)` · `Infracost`

### Security
`Kyverno` · `OPA/Gatekeeper` · `Falco` · `cert-manager` · `Linkerd (mTLS)` · `External Secrets Operator` · `GitLeaks` · `Semgrep` · `Trivy` · `OWASP Dependency-Check` · `OWASP ZAP` · `Checkov` · `Conftest`

### Observability
`Prometheus` · `Grafana` · `Loki 3.6` · `Promtail` · `Tempo` · `OpenTelemetry Collector` · `OpenTelemetry Operator` · `AlertManager` · `Prometheus Pushgateway`

### Platform Tools
`Kong` · `AWS Load Balancer Controller` · `External DNS` · `Cluster Autoscaler` · `Metrics Server` · `PostgreSQL` · `SonarQube` · `DefectDojo` · `Backstage` · `LitmusChaos` · `OpenCost`

### Microservices (Python)
`FastAPI` · `uvicorn` · `prometheus-client` · `httpx`

---

## Repository Structure

```
intelliops-sherlock/
├── README.md                    ← You are here
├── terraform/                   ← AWS infrastructure
│   ├── environments/dev/        ← Dev environment (main.tf, backend.tf, versions.tf)
│   └── modules/                 ← vpc, eks, ecr, iam, secrets, aiops
├── scripts/
│   ├── install-stack.sh         ← 28-step installer (resumable)
│   ├── configure-stack.sh       ← Post-install configuration
│   └── destroy-stack.sh         ← Full teardown with --bg and --skip-ns flags
├── k8s/
│   ├── apps/                    ← Microservice manifests (ArgoCD-managed)
│   ├── deployments/             ← AIOps workloads (ArgoCD-managed)
│   ├── argocd/                  ← ArgoCD Applications + AppProject definition
│   ├── helm-charts/             ← 20+ vendored Helm charts
│   ├── helm-values/             ← 26 values files (one per chart)
│   ├── kyverno-policies/        ← 7 security enforcement policies
│   ├── external-secrets/        ← SecretStore + 10 ExternalSecret mappings
│   ├── load-generator/          ← Locust K8s manifests (ArgoCD-managed)
│   ├── slos/                    ← SLO PrometheusRules (99.9% targets)
│   ├── grafana/                 ← 8 dashboard ConfigMaps
│   ├── gatekeeper/              ← OPA constraint templates
│   └── ingress/                 ← Kong ingress routes (all services)
├── services/
│   ├── order-service/           ← FastAPI service (Dockerfile + main.py)
│   ├── payment-service/         ← FastAPI service (Dockerfile + main.py)
│   ├── inventory-service/       ← FastAPI service (Dockerfile + main.py)
│   └── load-generator/          ← Locust load tester (locustfile.py + Dockerfile)
├── .github/workflows/           ← 11 CI/CD pipeline stages
├── policy/conftest/             ← OPA/Rego IaC security rules
└── docs/                        ← All documentation
```

---

## Documentation — Learning Path

| # | Document | Read Time | What You Learn |
|---|----------|-----------|---------------|
| 1 | [Quick Start](docs/01-quickstart.md) | 30 min | Step-by-step setup and first login |
| 2 | [Architecture](docs/02-architecture.md) | 45 min | How all 25+ components connect |
| 3 | [Infrastructure (Terraform + AWS)](docs/03-infrastructure.md) | 45 min | Every AWS resource, module internals |
| 4 | [Microservices & APIs](docs/04-microservices.md) | 30 min | Service design, metrics, OTEL operator |
| 5 | [CI/CD Pipeline](docs/05-cicd-pipeline.md) | 60 min | All 11 stages, security gates, Cosign |
| 6 | [Platform Tools Reference](docs/06-platform-tools.md) | 90 min | Every Helm chart explained with interview Qs |
| 7 | [Observability Guide](docs/07-observability.md) | 60 min | Traces, logs, metrics, dashboards |
| 8 | [Security & Compliance](docs/08-security-compliance.md) | 60 min | Every security layer explained |
| 9 | [ArgoCD & GitOps](docs/09-argocd-gitops.md) | 45 min | GitOps model, Applications, sync strategy |
| 10 | [SLOs & Alerting](docs/10-slos-alerting.md) | 45 min | Error budgets, burn-rate math |
| 11 | [AIOps Guide](docs/11-aiops.md) | 45 min | AI agent, anomaly detection, auto-remediation |
| 12 | [Cost & AWS Console Guide](docs/12-cost-aws-guide.md) | 30 min | Every AWS resource + where to find it |
| 13 | [Troubleshooting](docs/13-troubleshooting.md) | Reference | Real error messages + exact fixes |
| 14 | [Chaos & Load Testing](docs/14-chaos-load-testing.md) | 60 min | Locust scenarios, chaos endpoints, where to watch |
| 15 | [Adding a New Service](docs/15-add-new-service.md) | 45 min | Full guide: code → ECR → K8s → CI/CD → secure → observe |
| 16 | [Adding Helm Charts](docs/16-helm-charts.md) | 30 min | Vendor, values, ArgoCD Application, upgrades |
| 17 | [One-Click Automation](docs/17-one-click-automation.md) | 20 min | What's automated, what's manual, day-2 ops |

---

*Built for learning. Designed to break. Fix it, understand it, own it.*
