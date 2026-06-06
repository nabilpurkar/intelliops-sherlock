# Architecture Deep Dive

> **What you'll learn:** How all 25+ components connect, what data flows where, how a request moves from user to service, how a metric becomes an alert, and why the system is designed this way.

---

## The Big Picture in One Story

Imagine a developer pushes a code change at 9am. Here's what happens automatically:

1. **GitHub Actions** runs 11 security checks: secret scan, SAST, SCA, unit tests, IaC scan, container scan, build, sign, manifest update, ArgoCD sync, DAST
2. **ArgoCD** detects the new image tag in the git manifest and deploys the new version using a rolling update
3. **Kyverno** validates the pod at admission: correct security context, resource limits, signed image from ECR — blocks it if anything fails
4. **OTEL Operator** injects the Python SDK into the pod via an init container — no code changes needed
5. A **Locust** load test fires requests through **Kong API Gateway**
6. **Prometheus** scrapes custom metrics (`order_requests_total`) — an SLO burn-rate alert fires when error rate exceeds the 1-hour window threshold
7. **Loki** aggregates logs from all pods via **Promtail**
8. **Tempo** stores distributed traces from all three services — you can see the full call chain: `order → inventory → payment`
9. The **Anomaly Detector** ML model detects a spike in error rate, pushes to **SQS**
10. The **AI Agent** (Claude Sonnet via Bedrock) reads the alert, checks pod logs, and patches the deployment

That entire flow — from commit to alert to auto-fix — runs on this platform.

---

## Layer Architecture

```
╔══════════════════════════════════════════════════════════════════════╗
║  LAYER 1: EXTERNAL TRAFFIC                                            ║
║                                                                        ║
║  User Browser / API Client                                             ║
║       │                                                                ║
║       ▼                                                                ║
║  Route53 (*.yourdomain.com)  ──►  ACM Certificate (wildcard TLS)     ║
║       │                                                                ║
║       ▼                                                                ║
║  AWS ALB (Application Load Balancer)                                   ║
║       │  One ALB serves all services via Kong ingress group           ║
╚═══════╪══════════════════════════════════════════════════════════════╝
        │
╔═══════▼══════════════════════════════════════════════════════════════╗
║  LAYER 2: API GATEWAY (kong namespace)                                ║
║                                                                        ║
║  Kong Proxy (ClusterIP)                                                ║
║  Routes: /orders → order-service:8000                                 ║
║           /payments → payment-service:8002                            ║
║           /inventory → inventory-service:8001                         ║
║  Also routes: ArgoCD, Grafana, Prometheus, SonarQube, etc.            ║
╚═══════╪══════════════════════════════════════════════════════════════╝
        │
╔═══════▼══════════════════════════════════════════════════════════════╗
║  LAYER 3: APPLICATIONS (apps namespace)                               ║
║                                                                        ║
║  order-service (port 8000)  ──►  inventory-service (8001)            ║
║         │                    └►  payment-service (8002)              ║
║         │                                                              ║
║  All pods: Linkerd sidecar (mTLS), OTEL SDK injected, Prometheus     ║
║  scrape via ServiceMonitor, HPA (2-4 replicas based on CPU/mem)       ║
╚═══════╪══════════════════════════════════════════════════════════════╝
        │
╔═══════▼══════════════════════════════════════════════════════════════╗
║  LAYER 4: OBSERVABILITY (monitoring namespace)                         ║
║                                                                        ║
║  ┌─────────────┐  ┌──────────────┐  ┌────────────────────────────┐   ║
║  │  METRICS    │  │   LOGS       │  │     TRACES                 │   ║
║  │─────────────│  │──────────────│  │────────────────────────────│   ║
║  │ Prometheus  │  │ Loki         │  │ Tempo                      │   ║
║  │ scrapes all │  │ stores logs  │  │ stores spans               │   ║
║  │ pods via    │  │              │  │                            │   ║
║  │ ServiceMon. │  │ Promtail     │  │ OTEL Collector             │   ║
║  │             │  │ reads pod    │  │ receives from pods         │   ║
║  │ AlertManager│  │ logs and     │  │ exports to Tempo +         │   ║
║  │ routes      │  │ ships to     │  │ Prometheus (metrics gen)   │   ║
║  │ alerts      │  │ Loki         │  │                            │   ║
║  │             │  │              │  │                            │   ║
║  │      ◄──────┼──┼──────────────┼──┼── Grafana (visualization) │   ║
║  └─────────────┘  └──────────────┘  └────────────────────────────┘   ║
╚═══════╪══════════════════════════════════════════════════════════════╝
        │
╔═══════▼══════════════════════════════════════════════════════════════╗
║  LAYER 5: SECURITY (cluster-wide)                                     ║
║                                                                        ║
║  Kyverno (7 admission policies)     ← Blocks bad pods at create time ║
║  OPA Gatekeeper (2 policies)        ← Registry + label enforcement   ║
║  Falco (DaemonSet)                  ← Runtime kernel-level detection ║
║  cert-manager                       ← TLS certs for all services     ║
║  Linkerd (sidecar injection)        ← mTLS between all services      ║
║  External Secrets Operator          ← AWS SM → K8s Secret sync       ║
╚═══════╪══════════════════════════════════════════════════════════════╝
        │
╔═══════▼══════════════════════════════════════════════════════════════╗
║  LAYER 6: AIOPS (aiops-demo namespace)                               ║
║                                                                        ║
║  Anomaly Detector  ──►  SQS (intelliops-anomalies)                   ║
║  Alert Correlator  ──►  SQS                                          ║
║  Forecaster        ──►  Prometheus remote write                      ║
║  AI Agent          ◄──  SQS  ──►  AWS Bedrock (Claude Sonnet)       ║
║                         Reads K8s logs, patches deployments          ║
╚═══════╪══════════════════════════════════════════════════════════════╝
        │
╔═══════▼══════════════════════════════════════════════════════════════╗
║  LAYER 7: AWS INFRASTRUCTURE (Terraform-managed)                      ║
║                                                                        ║
║  VPC (10.0.0.0/16)  ──  3 public subnets  ──  NAT Gateway           ║
║  EKS Control Plane (managed)  ──  Node Group (4x t3.large, 2-6)     ║
║  ECR (8 repos)  ──  Secrets Manager (10 secrets)  ──  SQS           ║
╚══════════════════════════════════════════════════════════════════════╝
```

---

## Data Flow Maps

### Request Flow (User → API → Services)
```
User
  │
  ▼
Route53 (DNS lookup: apps.yourdomain.com → ALB IP)
  │
  ▼
ACM Certificate → TLS Termination
  │
  ▼
AWS ALB (listens on 443, routes to Kong NodePort)
  │
  ▼
Kong Proxy (path-based routing)
  │  /orders → order-service.apps:8000
  │  /payments → payment-service.apps:8002
  │  /inventory → inventory-service.apps:8001
  │
  ▼
Linkerd sidecar proxy (enforces mTLS, records L7 metrics)
  │
  ▼
order-service Pod
  │  POST /orders
  │  ├── GET http://inventory-service:8001/inventory/check (via httpx)
  │  └── POST http://payment-service:8002/payments/process (via httpx)
  │
  ▼
Response → Kong → ALB → User
```

### Metrics Flow (Application → Grafana)
```
order-service pod
  │  Prometheus client exposes /metrics
  │  order_requests_total{method="POST", status="200"} 42
  │
  ▼
Prometheus (scrape every 30s via ServiceMonitor)
  │  Stores in TSDB
  │  Evaluates PrometheusRules (SLO burn-rate)
  │  If burn > threshold → AlertManager
  │
  ▼
AlertManager → Slack webhook → #alerts channel
  │
  ▼
Grafana (queries Prometheus via PromQL)
  │  Dashboard: Services Overview, SLO Error Budget, DORA
```

### Trace Flow (OTEL Operator → Tempo → Grafana)
```
Pod creation
  │
  ▼
OTEL Operator detects annotation: inject-python=true
  │  Adds init container → mounts SDK packages to /otel-auto-instrumentation-python
  │  Sets PYTHONPATH to include SDK
  │  Python starts → sitecustomize.py auto-instruments FastAPI + httpx
  │
  ▼
Application receives request
  │  OTEL SDK creates span: order-service receives POST /orders
  │  Makes downstream call → propagates W3C TraceContext header
  │  inventory-service span: child of order-service span
  │  payment-service span: child of order-service span
  │
  ▼
OTEL SDK exports spans to OTEL Collector (http://otel-collector:4318)
  │
  ▼
OTEL Collector
  │  Receives OTLP (HTTP/protobuf)
  │  Exports to Tempo (gRPC port 4317) for trace storage
  │  Generates RED metrics → Prometheus remote write
  │
  ▼
Grafana → Explore → Tempo datasource
  │  Search by service, trace ID, or duration
  │  Click "Logs for this span" → jumps to Loki
```

### Log Flow (Pod → Loki → Grafana)
```
Pod stdout/stderr
  │
  ▼
Kubernetes node filesystem (/var/log/pods/...)
  │
  ▼
Promtail DaemonSet (runs on every node)
  │  Reads log files
  │  Adds labels: namespace, pod_name, container_name
  │  Parses JSON logs if structured
  │
  ▼
Loki (log aggregation, stores in compressed chunks)
  │
  ▼
Grafana → Explore → Loki datasource
  │  Query: {namespace="apps", pod=~"order.*"} |= "error"
  │  Correlate: click trace ID in log line → opens Tempo trace
```

### GitOps Flow (Git Push → Cluster Deploy)
```
Developer: git push to main
  │
  ▼
GitHub Actions CI (all 11 stages run in parallel where possible)
  │  GitLeaks, SAST, SCA, Unit Tests, SonarQube
  │  IaC Scan, Build+Push to ECR, Cosign sign
  │
  ▼
_update-manifests.yml
  │  kubectl patch k8s/apps/order-service.yaml
  │  Updates: image: ecr/order-service:NEW_SHA
  │  git commit + push to manifest branch
  │
  ▼
ArgoCD detects change (polls git every 3 min OR webhook)
  │
  ▼
ArgoCD diff: current cluster state vs git desired state
  │  Sees new image tag → plans RollingUpdate
  │
  ▼
Kyverno Admission Webhook intercepts new pod
  │  Checks: signed image? ✓  resource limits? ✓  ECR registry? ✓
  │  If any check fails: pod rejected, deployment stalls, ArgoCD shows Degraded
  │
  ▼
New pod starts → OTEL Operator injects SDK → pod is Ready
  │
  ▼
Old pod terminates (0 downtime via RollingUpdate maxUnavailable=0)
```

---

## Namespace Map

```
kube-system          ─── AWS LB Controller, CoreDNS, cluster-autoscaler, metrics-server
cert-manager         ─── cert-manager (Let's Encrypt)
external-secrets     ─── External Secrets Operator
external-dns         ─── ExternalDNS (Route53 automation)
linkerd              ─── Linkerd control plane + sidecar injection
monitoring           ─── Prometheus, Grafana, Loki, Tempo, OTEL Collector, OpenCost, Pushgateway
argocd               ─── ArgoCD server + application controller + repo server
kong                 ─── Kong proxy + ingress controller
database             ─── PostgreSQL (shared for SonarQube + DefectDojo + Kong + ArgoCD)
sonarqube            ─── SonarQube Community Edition
defectdojo           ─── DefectDojo security findings aggregator
falco                ─── Falco DaemonSet (runtime security)
kyverno              ─── Kyverno admission controller
gatekeeper-system    ─── OPA Gatekeeper
backstage            ─── Backstage developer portal
litmus               ─── LitmusChaos control plane
apps                 ─── order-service, payment-service, inventory-service, Locust
locust               ─── Locust load generator
aiops-demo           ─── AI Agent, Anomaly Detector, Alert Correlator, Forecaster
```

---

## Key Design Decisions

### Why public subnets in dev?
Private subnets require NAT for all outbound traffic. In dev with 4+ nodes pulling ECR images continuously, NAT costs add up. Public subnets with properly scoped security groups (EKS manages these) are sufficient for a learning environment. Production should use private subnets.

### Why one ALB for everything?
The Kong ingress group `intelliops-alb` consolidates all services behind a single ALB with path-based and host-based routing. This costs ~$0.016/hour instead of $0.016 × 10 services = $0.16/hour for separate ALBs. Kong does the L7 routing.

### Why both Kyverno AND Gatekeeper?
This is intentional for learning. Real organizations often migrate from one to the other. Gatekeeper (OPA/Rego) is the original approach — you write Rego policies. Kyverno is Kubernetes-native — you write YAML policies. In this project, Gatekeeper enforces registry + label rules, while Kyverno enforces security context + resource limits + image signing. In production, you'd pick one.

### Why OTEL Operator instead of code instrumentation?
The OTEL Operator injects the Python SDK as an init container — your application code has zero OTEL imports. This means: (1) services stay clean, (2) you can instrument any existing app without redeployment, (3) you can update the SDK version cluster-wide by updating the Instrumentation resource, not each service's code.

### Why Linkerd over Istio?
Linkerd is significantly lighter-weight than Istio. For a learning platform on t3.large nodes, Istio's control plane would consume a meaningful fraction of available memory. Linkerd's sidecar (linkerd-proxy) adds ~20MB per pod. Istio's envoy sidecar adds ~100-150MB. For 10+ pods, that's a significant difference.

---

## Interview Questions — Architecture

**Q1: How does GitOps work in this platform? What's the deployment flow?**
> *Answer:* "We use ArgoCD as the GitOps engine. The CI pipeline builds a container image, pushes to ECR, then updates the image tag in the Kubernetes manifest file in git. ArgoCD continuously polls the git repository (or receives a webhook) and detects the diff between the git desired state and the cluster's actual state. It then applies the changes using the Kubernetes API. The key principle is that git is the single source of truth — no `kubectl apply` in CI, no manual deployments."

**Q2: How do you ensure zero-downtime deployments?**
> *Answer:* "Three mechanisms work together. First, Kubernetes `RollingUpdate` strategy with `maxUnavailable: 0` and `maxSurge: 1` — the old pod stays up until the new one passes readiness checks. Second, readiness probes on `/ready` endpoints — the new pod only receives traffic when it returns 200. Third, `startupProbe` with `failureThreshold: 10` gives slow-starting pods time to initialize. Linkerd also adds an outbound connection draining period before terminating the old pod."

**Q3: If a microservice is throwing 500 errors, how do you debug it?**
> *Answer:* "Four tools in order: First, Grafana's Services Overview dashboard shows the error rate and when it started. Second, Tempo lets me find a specific failing trace by filtering on `http.status_code=500` — I can see exactly which downstream call failed and at what latency. Third, I click 'Logs for this span' from the trace view — it jumps to Loki and shows the exact log line with the stack trace. Fourth, if I need to go deeper, I use `kubectl exec` to check the running pod's environment, or `kubectl describe pod` to see if there are OOMKilled or CrashLoopBackOff events."

**Q4: How does the AIOps auto-remediation work end-to-end?**
> *Answer:* "The Anomaly Detector runs an ML model trained on Prometheus metrics. When it detects an anomaly — say, a 3x spike in error rate — it publishes a structured message to an AWS SQS queue. The AI Agent pod polls the SQS queue. When it gets a message, it uses IRSA to authenticate to AWS Bedrock and invokes Claude Sonnet. It passes the alert details plus the relevant pod logs. Claude analyzes the situation and returns a recommendation — could be 'scale up the deployment', 'restart the pod', or 'check this specific config'. The AI Agent then executes the Kubernetes API call automatically."

**Q5: What happens if Kyverno is down? Can I still deploy?**
> *Answer:* "By default, Kyverno is configured with a 'fail-open' webhook policy — if the Kyverno webhook is unreachable, Kubernetes admits the pod without policy checks. This is intentional for availability: platform components like Prometheus and ArgoCD must be able to restart even if Kyverno has issues. For production, you'd run 3 Kyverno replicas and configure failure policies per-policy based on criticality. The image signature verification policy would be 'fail-closed' (reject if webhook unavailable) while the resource limits check might be 'fail-open'."
