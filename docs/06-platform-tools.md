# Platform Tools Reference

> **What you'll learn:** Every Helm chart we deploy, why it was chosen over alternatives, its key configuration parameters, whether it has a UI, and how to explain it in an interview.

---

## Overview

28 platform components are installed by `install-stack.sh`. They fall into 6 categories:

| Category | Tools |
|----------|-------|
| **Core Infrastructure** | cert-manager, External Secrets Operator, metrics-server, Cluster Autoscaler |
| **Observability** | Prometheus + Grafana, Loki, Promtail, Tempo, OTEL Collector, OTEL Operator, Alertmanager, Pushgateway |
| **Networking & Traffic** | Kong API Gateway, AWS Load Balancer Controller, ExternalDNS, Linkerd |
| **Security** | Kyverno, OPA Gatekeeper, Falco, cert-manager |
| **Developer Tools** | ArgoCD, SonarQube, DefectDojo, Backstage, LitmusChaos |
| **FinOps & AI** | OpenCost, AIOps workloads |

---

## Core Infrastructure

### cert-manager (Step 1)

**What is it?**
> "cert-manager is a powerful and extensible X.509 certificate controller for Kubernetes and OpenShift workloads. It will obtain certificates from a variety of Issuers, both popular public Issuers as well as private Issuers, and ensure the certificates are valid and up to date." — cert-manager.io

**Why do we install it first?** Almost every other component needs TLS certificates. cert-manager must exist before anything that needs a certificate — including the OTEL Operator's admission webhook, Linkerd's mTLS certs, and all HTTPS ingresses.

**What it does in this project:**
- Generates TLS certificates for the OTEL Operator admission webhook (required for the webhook server to start)
- Could be configured to issue Let's Encrypt certificates — instead we use ACM wildcard cert via ALB, so cert-manager here is primarily for internal cluster certificates

**Key concepts:**
- `Issuer` / `ClusterIssuer`: Defines a source of certificates (Let's Encrypt, self-signed, Vault)
- `Certificate`: A Kubernetes resource requesting a certificate from an Issuer
- `CertificateRequest`: Auto-created by cert-manager when it needs to renew
- Webhook: cert-manager runs a mutating webhook that auto-injects cert fields

**No UI.** Verify with:
```bash
kubectl get certificates -A
kubectl get certificaterequests -A
```

---

### External Secrets Operator (Steps 2-3)

**What is it?**
> "External Secrets Operator is a Kubernetes operator that integrates external secret management systems like AWS Secrets Manager, HashiCorp Vault, Google Cloud Secrets Manager, and many more." — external-secrets.io

**Why not just use Kubernetes Secrets directly?**
Kubernetes Secrets are only base64-encoded (not encrypted at rest by default). Storing passwords in a git repo (even encoded) is a security violation. ESO keeps secrets in AWS Secrets Manager (encrypted, audited, IAM-controlled) and syncs them as K8s Secrets automatically.

**How it works in this project:**
```
AWS Secrets Manager
  intelliops/dev/grafana → { admin_password: "abc123" }
           │
           ▼ (ESO polls every 1h)
  ClusterSecretStore (IRSA role → SM read access)
           │
           ▼
  ExternalSecret CR: "sync grafana admin_password → k8s Secret grafana-credentials"
           │
           ▼
  Kubernetes Secret: grafana-credentials
           │
           ▼
  Grafana Helm values: admin.existingSecret: grafana-credentials
```

**Key parameters we set:**
```yaml
# helm-values/eso-values.yaml
installCRDs: true
replicaCount: 2   # HA — ESO is critical path
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: <eso-irsa-arn>  # IRSA for SM access
```

**No UI.** Check sync status:
```bash
kubectl get externalsecret -A
# STATUS column shows SecretSynced or SecretSyncError
kubectl describe externalsecret grafana-secret -n monitoring
```

---

### metrics-server (Step 6)

**What is it?**
> "Metrics Server is a scalable, efficient source of container resource metrics for Kubernetes built-in autoscaling pipelines." — Kubernetes SIGs

**Why needed?** The Horizontal Pod Autoscaler (HPA) needs CPU/memory metrics to make scaling decisions. Without metrics-server, `kubectl top pods` returns nothing and HPA can't function.

**Key config:**
```yaml
args:
  - --kubelet-insecure-tls   # Required on some EKS versions
  - --metric-resolution=15s  # How often to scrape kubelet
```

**No UI.** Verify:
```bash
kubectl top nodes
kubectl top pods -n apps
```

---

### Cluster Autoscaler (Step 7)

**What is it?**
> "Cluster Autoscaler is a tool that automatically adjusts the size of a Kubernetes cluster so that all pods have a place to run and there are no unneeded nodes." — Kubernetes SIGs

**How it works:**
```
HPA detects high CPU → adds pod
Pod is Pending (no node has capacity)
         │
         ▼
Cluster Autoscaler detects Pending pods
Calls AWS EC2 API: increase node group desired capacity
New node joins cluster (takes ~3-4 min)
Pod is scheduled on new node
```

**Key config:**
```yaml
autoDiscovery:
  clusterName: intelliops-dev   # Uses cluster tag to find node groups
extraArgs:
  scale-down-delay-after-add: "10m"    # Wait 10m before scale-down
  skip-nodes-with-system-pods: "false"  # Allow scale-down even with system pods
  balance-similar-node-groups: "true"   # Keep nodes balanced across AZs
```

**Why IRSA?** The autoscaler calls EC2 APIs to scale the node group. It uses the IRSA role to avoid embedding AWS credentials.

**No UI.** Check logs:
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=cluster-autoscaler -f
```

---

## Observability Stack

### Prometheus + Grafana (kube-prometheus-stack, Step 12)

**What is it?**
> "The Prometheus monitoring system and time series database. Prometheus collects and stores its metrics as time series data." — prometheus.io

> "Grafana allows you to query, visualize, alert on and understand your metrics no matter where they are stored." — Grafana Labs

**Why kube-prometheus-stack?** This single Helm chart deploys Prometheus, Grafana, Alertmanager, node-exporter (collects OS metrics), and kube-state-metrics (collects K8s object metrics) — all pre-wired together. The alternative (deploying each separately) requires significant integration work.

**What gets collected:**
- Node metrics: CPU, memory, disk, network (node-exporter)
- Kubernetes metrics: pod restarts, deployment health, PVC usage (kube-state-metrics)
- Application metrics: `order_requests_total`, `payment_request_duration_secs_*` (custom ServiceMonitors)
- Cluster metrics: API server latency, etcd size, scheduler queue depth

**Key values we set:**
```yaml
prometheus:
  prometheusSpec:
    retention: 15d                      # Keep 15 days of metrics
    storageSpec:
      volumeClaimTemplate:
        spec:
          resources:
            requests:
              storage: 50Gi             # gp3 EBS volume
    serviceMonitorSelectorNilUsesHelmValues: false  # Pick up ALL ServiceMonitors
    ruleSelectorNilUsesHelmValues: false            # Pick up ALL PrometheusRules

grafana:
  adminPassword: ""                     # Sourced from K8s secret (ESO-synced from SM)
  persistence:
    enabled: true
    size: 10Gi
  dashboardProviders:
    dashboardproviders.yaml:
      providers:
        - name: default
          folder: ''
          type: file
          options:
            path: /var/lib/grafana/dashboards/default
  dashboardsConfigMaps:                # Our 8 dashboard ConfigMaps
    - configMapName: dashboard-services
      fileName: dashboard-services.json
```

**UI:** `https://grafana.yourdomain.com` → login with admin / (password from INSTRUCTIONS.md)

**Why use ServiceMonitor instead of static scrape configs?**
ServiceMonitor is a Kubernetes CRD. When you create one, Prometheus automatically picks up the new scrape target without restarting or editing any config file. This is the GitOps-friendly way — adding a service = adding a ServiceMonitor.

---

### Loki (Step 13)

**What is it?**
> "Loki is a horizontally scalable, highly available, multi-tenant log aggregation system inspired by Prometheus. It is designed to be very cost effective and easy to operate. It does not index the contents of the logs, but rather a set of labels for each log stream." — Grafana Labs

**The key insight:** Prometheus indexes metric values. Loki indexes only log **labels** (pod name, namespace, container) — not the log text itself. This makes Loki dramatically cheaper than Elasticsearch for log storage, at the cost of slower full-text search.

**How logs flow:**
```
App pod (stdout) → Promtail DaemonSet → Loki → Grafana Explore
```

**Label-based querying (LogQL):**
```logql
# All logs from order-service in the last 5 minutes
{namespace="apps", app="order-service"} | json | level="error"

# Count of error logs per minute
sum(rate({namespace="apps"} |= "ERROR" [1m])) by (app)
```

**Version we use:** Loki 3.6.7 (Grafana/Loki chart). Installed separately from the kube-prometheus-stack.

**Key values:**
```yaml
loki:
  commonConfig:
    replication_factor: 1          # Single replica for dev cost savings
  storage:
    type: filesystem               # Local disk (use S3 for prod)
  limits_config:
    retention_period: 168h         # 7 days of logs
```

**No separate UI** — accessed via Grafana → Explore → select Loki datasource.

---

### Promtail (Step 13a)

**What is it?**
> "Promtail is an agent which ships the contents of local logs to a Loki instance." — Grafana Labs

**How it works:** Runs as a DaemonSet (one pod per node). Each pod tails container log files from `/var/log/pods/` on the node and ships them to Loki with Kubernetes labels auto-attached.

**Auto-labeling:**
```
Container log line: "2024-01-15 INFO Order created: ord-abc123"
→ Promtail adds: namespace="apps", pod="order-service-7d4b8f-abc", container="order-service"
→ Stored in Loki with these labels
```

**No separate UI.** Verify:
```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=promtail
# Should be 1 pod per node (DaemonSet)
```

---

### Tempo (Step 14)

**What is it?**
> "Grafana Tempo is an open source, easy-to-use and high-scale distributed tracing backend." — Grafana Labs

**What is distributed tracing?** When a request to `/orders` calls inventory and payment services, you want to see all three service calls as a single "trace" with timing. Each service emits "spans" with a common trace ID — Tempo collects and correlates them.

**Why Tempo over Jaeger?** Tempo is object-storage native (uses S3 or local disk), requires no separate database, and integrates directly with Grafana. Jaeger requires Elasticsearch or Cassandra — much more infrastructure.

**How it connects:**
```
Service pods → OTEL Collector → Tempo
                                  │
                              Grafana → Search by trace ID, service, duration
```

**Key config:**
```yaml
tempo:
  storage:
    trace:
      backend: local              # local disk for dev; use s3 for prod
      local:
        path: /var/tempo/traces
  metricsGenerator:
    enabled: true                 # Generates span metrics → Prometheus
    remoteWriteUrl: "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/api/v1/write"
```

**No separate UI** — accessed via Grafana → Explore → select Tempo datasource.

---

### OpenTelemetry Collector (Step 15)

**What is it?**
> "The OpenTelemetry Collector offers a vendor-agnostic implementation of how to receive, process, and export telemetry data (traces, metrics, logs)." — OpenTelemetry

**Think of it as a telemetry router.** Services send traces to the Collector, and the Collector forwards them to Tempo. This decoupling means you can:
- Change from Tempo to Jaeger without touching a single service
- Add processing (sampling, attribute enrichment) in one place
- Fan out to multiple backends simultaneously

**Pipeline config:**
```yaml
config:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317    # gRPC (used by OTEL Operator auto-instrumentation)
        http:
          endpoint: 0.0.0.0:4318    # HTTP (used by Instrumentation CRD endpoint)
  processors:
    batch:
      timeout: 5s                   # Buffer spans for 5s before sending
      send_batch_size: 512
    memory_limiter:
      limit_mib: 256
  exporters:
    otlp:
      endpoint: "tempo.monitoring.svc.cluster.local:4317"
      tls:
        insecure: true
  service:
    pipelines:
      traces:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [otlp]
```

---

### OpenTelemetry Operator (Step 15b)

**What is it?**
> "The OpenTelemetry Operator is an implementation of a Kubernetes Operator, that manages OpenTelemetry Collectors and auto-instrumentation of the workloads using OpenTelemetry instrumentation libraries." — OpenTelemetry

**The key feature:** Zero-code auto-instrumentation. Add one annotation to a pod, and Python/Java/Node.js is automatically instrumented — no library imports, no code changes.

**How it works:**
1. `Instrumentation` CRD defines SDK config (endpoint, propagators, sampler)
2. Pod annotation `instrumentation.opentelemetry.io/inject-python: "true"` triggers the webhook
3. OTEL Operator's MutatingAdmissionWebhook intercepts pod creation
4. Adds init container that copies SDK into a shared volume
5. Sets `PYTHONPATH` to include the SDK
6. Python starts → `sitecustomize.py` bootstraps OTEL → all FastAPI routes and httpx calls are traced

**Requires cert-manager** to manage the webhook's TLS certificate — this is why cert-manager is installed first.

---

### Kong API Gateway (Step 16)

**What is it?**
> "Kong Gateway is a lightweight, fast, and flexible cloud-native API gateway. It's a Lua application running in Nginx, and it's made possible by the lua-nginx-module." — Kong Inc.

**Why a dedicated API gateway?**
Without Kong, you'd need a separate ALB + DNS record per service (expensive and complex to manage). With Kong:
- Single ALB for all services
- Path-based routing: `/orders` → order-service, `/payments` → payment-service
- Apply rate limiting, authentication, CORS, logging as plugins — once, centrally
- Traffic splitting for canary releases

**Routing in this project:**
```
ALB (one IP, *.yourdomain.com)
  └── Kong proxy
        ├── /orders*         → order-service:8000
        ├── /payments*       → payment-service:8002
        ├── /inventory*      → inventory-service:8001
        ├── /argocd*         → argocd-server:80
        ├── /grafana*        → grafana:80
        └── /prometheus*     → prometheus:9090
```

**Key values:**
```yaml
ingressController:
  enabled: true
  installCRDs: true
env:
  database: "off"           # DB-less mode — config from Kubernetes Ingress/KongIngress
proxy:
  type: LoadBalancer         # Creates AWS ALB via aws-load-balancer-controller
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "external"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
```

**UI:** `https://kong-admin.yourdomain.com` — manage routes, plugins, certificates.

---

### AWS Load Balancer Controller (Step 5)

**What is it?**
> "AWS Load Balancer Controller is a controller to help manage Elastic Load Balancers for a Kubernetes cluster. It satisfies Kubernetes Ingress resources by provisioning Application Load Balancers." — AWS

**Why install before Kong?** Kong's proxy Service needs a LoadBalancer, which creates an ALB. The ALB is provisioned by this controller — it must exist before any `Service.type=LoadBalancer` or Ingress resource.

**What it does:** Watches Kubernetes Service and Ingress resources with ALB annotations, then calls AWS APIs to create/update/delete ALBs automatically.

**IRSA requirement:** The controller calls EC2, ELB, IAM, and Route53 APIs — it uses IRSA role `intelliops-dev-alb-irsa` to avoid hardcoded credentials.

---

### ExternalDNS (Step 8)

**What is it?**
> "ExternalDNS synchronizes exposed Kubernetes Services and Ingresses with DNS providers." — Kubernetes SIGs

**What it does:** Watches Ingress resources. When it sees an Ingress with hostname `grafana.yourdomain.com` pointing to an ALB, it automatically creates a Route53 CNAME record `grafana.yourdomain.com → alb-abc123.us-east-1.elb.amazonaws.com`.

Without ExternalDNS, you'd manually create a DNS record for every service — and update it every time the ALB DNS name changes.

**Key values:**
```yaml
provider: aws
aws:
  region: us-east-1
  zoneType: public
domainFilters:
  - yourdomain.com            # Only manage records in this zone
policy: sync                  # Delete DNS records when Ingress is deleted
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: <external-dns-irsa-arn>
```

---

### Linkerd (Steps 9-10)

**What is it?**
> "Linkerd is an ultralight, security-first service mesh for Kubernetes. Linkerd adds critical security, observability, and reliability features to your Kubernetes stack with no code change required." — Linkerd

**What is a service mesh?** A service mesh adds a transparent proxy (sidecar) to every pod. All network traffic between pods goes through these proxies, giving you:
- **mTLS**: Automatic mutual TLS between all services — without any application code
- **Observability**: Request rates, latency, error rates per service-to-service connection
- **Traffic policies**: Retries, timeouts, circuit breaking

**How mTLS works in Linkerd:**
```
order-service pod                         payment-service pod
  ├── order-service container             ├── payment-service container
  └── linkerd-proxy (sidecar)    ←mTLS→  └── linkerd-proxy (sidecar)
```

The proxies handle certificate management automatically — the application containers don't know about TLS at all.

**Why two-step install (crds then control plane)?**
Linkerd CRDs must exist before the control plane is deployed so Kubernetes can validate the custom resource types.

**Important:** Linkerd requires its certificates (trust anchor + issuer) to be pre-created in Secrets Manager. `install-stack.sh` generates them with `step` CLI and stores them in SM before deployment.

---

## Security Stack

### Kyverno (Step 20)

**What is it?**
> "Kyverno is a policy engine designed for Kubernetes. With Kyverno, policies are managed as Kubernetes resources and no new language is required to write policies." — Nirmata / CNCF

**7 policies deployed:**

| Policy | Action | What It Blocks |
|--------|--------|----------------|
| `disallow-latest-tag` | Enforce | Images tagged `:latest` (non-deterministic) |
| `disallow-privileged` | Enforce | Containers with `privileged: true` |
| `disallow-host-namespaces` | Enforce | `hostPID`, `hostNetwork`, `hostIPC` |
| `require-pod-security-context` | Enforce | Pods without `runAsNonRoot: true` |
| `require-resource-limits` | Enforce | Containers without CPU/memory limits (apps ns) |
| `restrict-image-registries` | Enforce | Images not from our ECR registry |
| `verify-image-signatures` | Enforce | Images without valid Cosign signature (apps ns) |

**Enforce vs Audit:**
- `Enforce`: Pod creation is blocked — admission controller returns 403
- `Audit`: Pod is allowed but a `PolicyReport` is created — use for monitoring without breaking things

**Why is `require-resource-limits` only Enforce in apps namespace but Audit in monitoring?**
Third-party Helm charts (Prometheus, Loki) sometimes don't set resource limits on all pods. Blocking their installation would prevent upgrades. We audit-only for platform namespaces.

**Check policy violations:**
```bash
kubectl get policyreport -A
kubectl get clusterpolicyreport
```

---

### OPA Gatekeeper (Step 21)

**What is it?**
> "Open Policy Agent (OPA) is an open source, general-purpose policy engine that unifies policy enforcement across the stack." — OPA

**Kyverno vs Gatekeeper?** Both enforce admission policies. We run both to demonstrate both approaches:
- Kyverno: Kubernetes-native YAML policies, easier to write
- Gatekeeper: Rego language, more powerful for complex logic, audit-first approach

**Gatekeeper uses two-layer CRDs:**
1. `ConstraintTemplate`: defines the policy logic in Rego
2. `Constraint`: applies the template to specific resources

```rego
# ConstraintTemplate: require-labels
violation[{"msg": msg}] {
  provided := {label | input.review.object.metadata.labels[label]}
  required := {label | label := input.parameters.labels[_]}
  missing := required - provided
  count(missing) > 0
  msg := sprintf("Missing required labels: %v", [missing])
}
```

**No UI.** Check violations:
```bash
kubectl get constraints -A
kubectl describe constraint <name>
```

---

### Falco (Step 17)

**What is it?**
> "Falco is a cloud native runtime security tool that provides real-time threat detection for hosts, containers, and Kubernetes. Falco monitors system call activity to detect anomalous behavior." — Falco / CNCF

**The key difference from Kyverno:** Kyverno is admission-time (before containers run). Falco is runtime (while containers run). They catch different attack vectors:
- Kyverno: blocks a pod with a bad configuration before it starts
- Falco: detects when a running container suddenly reads `/etc/shadow` or spawns a shell

**What Falco detects:**
```
Pod running as root → Rule: "Non-root user expected"
Container spawning bash: exec bash -i → Rule: "Terminal shell in container"
Container reading /etc/passwd → Rule: "Read sensitive file"
Container writing to /etc → Rule: "Write below etc"
Container loading kernel module → Rule: "Linux kernel module injection"
Container accessing docker socket → Rule: "Contact Docker Socket"
```

**How it works:**
Falco runs as a privileged DaemonSet with access to the Linux kernel's eBPF or kernel module interface. It attaches to system calls (open, exec, connect) and evaluates rules in real time.

**Alerts go to:** Slack webhook (configured via `intelliops/dev/slack` secret) or any AlertManager-compatible endpoint.

**ServiceMonitor:** `k8s/grafana/falco-servicemonitor.yaml` — Falco exposes Prometheus metrics, visible in Grafana.

---

## Developer Tools

### ArgoCD (Step 11)

Covered in full detail in [09-argocd-gitops.md](09-argocd-gitops.md).

**Summary:** GitOps operator. Watches the git repo, syncs cluster state when YAML changes. Manages 3 Applications: microservices (apps ns), aiops (aiops-demo ns), locust (locust ns).

**UI:** `https://argocd.yourdomain.com`

---

### SonarQube (Step 18)

**What is it?**
> "SonarQube (formerly Sonar) is an open-source platform developed by SonarSource for continuous inspection of code quality to perform automatic reviews with static analysis of code to detect bugs and code smells." — SonarSource

**UI:** `https://sonarqube.yourdomain.com`

**What you see in the UI:**
- Project dashboard: code quality score, technical debt estimate
- Issues browser: bugs, vulnerabilities, code smells by file/function
- Security Hotspots: code that needs manual security review
- Coverage: percentage of code covered by tests
- Quality Gate status: pass/fail for CI blocking

**How it connects to CI:** The `_sonarqube.yml` workflow sends the scan report to this SonarQube server. The Quality Gate status is polled — if it fails, the CI job fails.

**Key setup:**
- PostgreSQL for storage (installed in Step 4 — SonarQube requires PostgreSQL)
- Password from Secrets Manager (never hardcoded)
- Project and access token created by `configure-stack.sh`

---

### DefectDojo (Step 19)

**What is it?**
> "DefectDojo is an open-source application vulnerability correlation and security orchestration tool. It provides tools to aggregate findings from security testing tools into one central location." — DefectDojo Inc.

**Think of it as the aggregator.** Every scanner (Semgrep, Trivy, Checkov, ZAP, OWASP DC) sends its SARIF report to DefectDojo via API. DefectDojo:
- Deduplicates findings (same CVE found by Trivy and Grype = 1 finding, not 2)
- Tracks finding lifecycle: Open → In Review → Mitigated → Closed
- Maps findings to OWASP Top 10, PCI-DSS, SOC2 controls
- Generates compliance reports

**UI:** `https://defectdojo.yourdomain.com`

**How findings flow:**
```
CI pipeline scanner → DefectDojo API
  POST /api/v2/import-scan/
    scan_type: SARIF
    product_name: IntelliOps Sherlock
    engagement_name: CI Pipeline - Semgrep
```

---

### Backstage (Step 26)

**What is it?**
> "Backstage is an open platform for building developer portals. Powered by a centralized service catalog, Backstage restores order to your microservices and infrastructure." — Spotify / CNCF

**UI:** `https://backstage.yourdomain.com`

**What it provides:**
- **Service Catalog**: Browse all services with owner, lifecycle stage, tech docs
- **TechDocs**: Markdown documentation rendered as a website (from the repo)
- **GitHub Actions plugin**: See CI pipeline status inline in the catalog
- **ArgoCD plugin**: See deployment status per service
- **Kubernetes plugin**: See pod health per service

**Why Backstage for teams?** As you add services, tracking "who owns what, where is the runbook, what are the dependencies" becomes hard. Backstage is a single portal where developers go first.

---

### LitmusChaos (Step 27)

**What is it?**
> "Litmus is an end-to-end open source chaos engineering platform that enables teams to identify weaknesses and potential outages in infrastructures by inducing chaos tests in a controlled way." — Litmuschaos / CNCF

**What is chaos engineering?** Deliberately breaking things in a controlled environment to verify your system recovers gracefully. The principle: if you don't test failure, your first failure will be a production incident.

**Experiments we can run:**
- Pod delete: Kill a random order-service pod — does HPA create a new one? Does the readiness probe work?
- Network chaos: Add 200ms latency to payment-service — do timeouts fire correctly?
- CPU stress: Spike CPU on inventory-service — does HPA scale up?
- Node drain: Simulate node failure — do topology spread constraints keep services up?

**UI:** LitmusChaos dashboard (accessed via ArgoCD or direct port-forward)

---

### OpenCost (Step 23)

**What is it?**
> "OpenCost is a vendor-neutral open source project for measuring and allocating cloud infrastructure and container costs in real time." — OpenCost / CNCF

**What it shows:**
- Cost per namespace: "monitoring namespace costs $2.30/day"
- Cost per service: "order-service costs $0.45/day (2 pods × 0.1 CPU × $0.0832/hr)"
- Cost efficiency: resource requests vs actual usage

**Why this matters:** Without cost visibility, teams over-provision (wasting money) or under-provision (causing OOMKills). OpenCost shows exactly what each service costs.

**Integration:** OpenCost pushes cost metrics to Prometheus → Grafana "FinOps Dashboard" shows trends.

---

## Interview Questions — Platform Tools

**Q1: Why run both Kyverno and OPA Gatekeeper? Isn't that redundant?**
> *Answer:* "They solve the same problem (admission control) but with different strengths. Kyverno is Kubernetes-native — policies are YAML, no separate language needed, very developer-friendly. Gatekeeper uses Rego — more complex but more powerful for advanced logic. In practice, most teams choose one. We run both to demonstrate both approaches for learning purposes. In a production setup, I'd choose Kyverno for most policies because the YAML syntax is easier for platform engineers to maintain, and use Gatekeeper only if we had policies requiring Rego's expressiveness."

**Q2: Why does Promtail run as a DaemonSet while Prometheus runs as a StatefulSet?**
> *Answer:* "Promtail needs to run on every node because it reads container log files directly from the node's filesystem at `/var/log/pods/`. A Deployment can't guarantee one pod per node. A DaemonSet guarantees exactly one Promtail pod per node, so no logs are missed. Prometheus is a StatefulSet because it has persistent volume claims for its time-series database — it needs a stable identity and storage that persists across restarts. A Deployment would lose metrics data on restart."

**Q3: What's the difference between Loki and Elasticsearch for log storage?**
> *Answer:* "Elasticsearch indexes every word in every log line — powerful full-text search but expensive (RAM + disk). Loki only indexes log labels (namespace, pod, container) — not the content. Log content is stored in compressed chunks and searched with regex/grep at query time. Loki is 10-50x cheaper for the same log volume. The trade-off: Loki is slower for complex full-text searches. For most Kubernetes use cases (find all errors for service X in the last hour), Loki is plenty fast. For compliance use cases requiring complex queries across years of logs, Elasticsearch/OpenSearch is better."

**Q4: How does ExternalDNS know which DNS records to create?**
> *Answer:* "ExternalDNS watches for Kubernetes Service and Ingress resources with specific annotations or hostnames. When Kong's LoadBalancer Service gets an external IP (ALB DNS name) from AWS, ExternalDNS sees the hostname annotation on Ingress resources (like `host: grafana.yourdomain.com`) and creates the corresponding Route53 record. It uses IRSA to call Route53's ChangeResourceRecordSets API without any hardcoded credentials. When an Ingress is deleted, ExternalDNS deletes the DNS record (if `policy: sync` is set)."

**Q5: Why does the anomaly-detector have an init container for model training?**
> *Answer:* "The ML model needs to be trained on real Prometheus data before the main container can use it for inference. We can't pre-train it because the data is environment-specific. The init container runs `train.py`, queries Prometheus for historical metrics, trains the isolation forest model, and saves it to a shared emptyDir volume at `/models/anomaly_model.pkl`. The main container starts only after the init container succeeds — it reads the model file from the same shared volume. This is the Kubernetes pattern for one-time initialization: init containers run sequentially before the main containers start."

---

## What's Next?

→ **[07-observability.md](07-observability.md)** — How Prometheus, Loki, Tempo, and Grafana work together
→ **[08-security-compliance.md](08-security-compliance.md)** — Kyverno policies, Falco rules, and mTLS in detail
→ **[09-argocd-gitops.md](09-argocd-gitops.md)** — How ArgoCD deploys and manages all these Helm charts
