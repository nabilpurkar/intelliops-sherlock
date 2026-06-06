# Observability Guide

> **What you'll learn:** The difference between metrics, logs, and traces, how they connect in this platform, how to query each one in Grafana, what the 8 pre-built dashboards show, and how to correlate a trace directly to its logs.

---

## The Three Pillars

Observability means you can understand what's happening inside your system by examining its outputs. The three pillars are:

```
METRICS                    LOGS                       TRACES
──────────                 ──────                     ──────
"What is happening?"       "What happened?"           "Why did it happen?"

Aggregate numbers          Timestamped text events    Request journey map
Stored as time series      Stored as indexed chunks   Stored as span trees
Queried with PromQL        Queried with LogQL         Queried by trace ID

Good for:                  Good for:                  Good for:
  Alerts & dashboards        Debugging details          Performance analysis
  SLO calculations           Error messages             Identifying slow calls
  Trend analysis             Audit trails               Service dependencies

Tool: Prometheus            Tool: Loki                 Tool: Tempo
UI: Grafana panels          UI: Grafana Explore        UI: Grafana Explore
```

**The real power:** Grafana connects all three. Click a spike in a Grafana panel → zoom into logs → jump to the distributed trace for that exact request.

---

## Metrics with Prometheus

### How Metrics Are Collected

```
Application pods                 Prometheus
  order-service:8000/metrics  ◄── scrape every 15s
  payment-service:8002/metrics ◄── scrape every 15s
  inventory-service:8001/metrics ◄── scrape every 15s

Node (OS metrics)               ← node-exporter DaemonSet
Kubernetes objects              ← kube-state-metrics
Kubernetes API server           ← kube-prometheus-stack built-in
```

### ServiceMonitors — The GitOps Way to Add Scrape Targets

Instead of editing Prometheus configuration files, we use `ServiceMonitor` CRDs:

```yaml
# k8s/apps/servicemonitors.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: order-service
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: order-service       # Selects the order-service Service
  namespaceSelector:
    matchNames: [apps]
  endpoints:
    - port: http
      path: /metrics
      interval: 15s
```

When you add a new service, add a ServiceMonitor — Prometheus picks it up automatically without restart.

### PromQL — Querying Metrics

Open Prometheus at `https://prometheus.yourdomain.com` and try these queries:

```promql
# Request rate — requests per second over the last 5 minutes
sum(rate(order_requests_total[5m])) by (status)

# Error rate — fraction of requests returning 5xx
sum(rate(order_requests_total{status=~"5.."}[5m])) /
sum(rate(order_requests_total[5m]))

# P95 latency — 95th percentile request duration
histogram_quantile(0.95, sum(rate(order_request_duration_seconds_bucket[5m])) by (le))

# Active order-service pods
kube_deployment_status_replicas_available{deployment="order-service"}

# Node memory usage (as % of allocatable)
1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)

# CPU throttling — are resource limits too tight?
sum(rate(container_cpu_cfs_throttled_periods_total{namespace="apps"}[5m]))
/ sum(rate(container_cpu_cfs_periods_total{namespace="apps"}[5m]))
```

### Key Metrics by Service

**Order Service:**
```
order_requests_total{status="201"}    — successful orders
order_requests_total{status="500"}    — failed orders (~2% rate)
order_request_duration_seconds_*      — latency histogram
orders_created_total{result="success"}
orders_active_total                   — in-flight orders
order_errors_total{error_type="timeout"}
db_query_duration_seconds_*           — simulated DB latency
```

**Payment Service:**
```
payment_requests_total{status="200"}
payment_requests_total{status="402"}  — declined (~1.5% rate)
payment_request_duration_secs_*       — note: _secs not _seconds
```

**Inventory Service:**
```
inventory_requests_total{status="200"}
inventory_requests_total{status="404"}  — out of stock (~0.5% rate)
inventory_request_duration_secs_*
```

---

## Logs with Loki

### How Logs Flow

```
Pod stdout/stderr
      │
      ▼
Kubernetes writes to /var/log/pods/<namespace>/<pod>/<container>.log on the node
      │
      ▼
Promtail DaemonSet (one per node) tails these files
  Adds labels: namespace, pod, container, app (from K8s pod labels)
      │
      ▼
Loki stores compressed chunks, indexed by labels
      │
      ▼
Grafana Explore → LogQL queries
```

### LogQL — Querying Logs

Open Grafana → Explore → select **Loki** datasource:

```logql
# All logs from order-service
{namespace="apps", app="order-service"}

# Only error logs
{namespace="apps"} |= "ERROR"

# Parse JSON logs and filter by field
{namespace="apps", app="order-service"} | json | level="error"

# Count errors per minute by service
sum(rate({namespace="apps"} |= "ERROR" [1m])) by (app)

# Find all logs for a specific order ID
{namespace="apps"} |= "ord-abc123"

# Show logs with latency > 1000ms
{namespace="apps", app="order-service"} | json | duration > 1000

# Platform component logs (ArgoCD sync activity)
{namespace="argocd"} |= "sync"
```

### Log Labels Available

All pods in the cluster have these labels automatically attached by Promtail:

```
namespace    — Kubernetes namespace
pod          — Pod name (includes random suffix)
container    — Container name
node         — Node name
app          — From pod label app= (if set)
```

---

## Distributed Tracing with Tempo

### What Is a Trace?

When a request comes in to order-service, it creates a "trace" — a unique trace ID that travels through every service the request touches:

```
Trace ID: abc-123-def-456
│
├── Span: POST /orders (order-service) 45ms
│     ├── Span: GET /inventory/check (inventory-service) 12ms
│     └── Span: POST /payments/process (payment-service) 18ms
│
└── All spans share trace ID — reconstructed into waterfall view in Grafana
```

### How Traces Are Generated (Zero Code Changes)

```
1. Request arrives at order-service pod
2. OTEL Operator injected the SDK via init container + PYTHONPATH
3. sitecustomize.py bootstrapped OTEL at Python startup
4. FastAPI route handler is wrapped with OTEL span auto-instrumentation
5. Span created: "POST /orders" with http.method, http.url, http.status_code attributes
6. order-service calls inventory-service via httpx
7. OTEL SDK injects W3C TraceContext headers: "traceparent: 00-abc123-def456-01"
8. inventory-service receives request, extracts trace ID from header
9. Creates child span: "GET /inventory/check" — linked to parent trace
10. Both spans exported → OTEL Collector → Tempo
```

### Querying Traces in Grafana

1. Go to Grafana → **Explore**
2. Select **Tempo** datasource
3. Click **Search** (not TraceQL)
4. Fill in:
   - Service Name: `order-service`
   - Span Name: `POST /orders`
   - Min Duration: `100ms` (find slow requests)
5. Click **Run Query**
6. Click any trace to open the waterfall view:
   ```
   order-service          ████████████████████████  45ms
     inventory-service    ████████                  12ms
     payment-service                ██████████      18ms
   ```

### TraceQL — Advanced Trace Queries

```traceql
# Find all traces with errors
{ status = error }

# Find traces slower than 500ms
{ duration > 500ms }

# Find order-service traces with downstream payment errors
{ resource.service.name = "order-service" } >> { resource.service.name = "payment-service" && status = error }

# Find traces where inventory check took > 50ms
{ resource.service.name = "inventory-service" && name = "GET /inventory/check" && duration > 50ms }
```

---

## Connecting Traces ↔ Logs (Exemplars)

This is one of the most powerful features: jump from a trace to the exact log lines for that request.

### How It Works

1. OTEL SDK adds `trace_id` and `span_id` to log lines (structured logging)
2. Loki stores the log with these fields as queryable attributes
3. Tempo has a "Logs" button per trace — clicks through to Loki filtered by trace ID

**Try it:**
```
1. Grafana → Explore → Tempo → Search → order-service
2. Click any trace
3. Click the "Logs" button in the trace panel
→ Jumps to Grafana Explore with LogQL:
   {namespace="apps"} | json | trace_id="abc-123-def-456"
→ Shows only the log lines generated during that exact request
```

---

## The 8 Grafana Dashboards

All dashboards are pre-loaded as ConfigMaps in `k8s/grafana/`. Find them at: Grafana → Dashboards → Browse.

### Dashboard 1: Services Overview (`dashboard-services.json`)

**What it shows:**
- Request rate per service (last 5m)
- Error rate per service (last 5m)
- P95 latency per service (last 5m)
- Active pod count per service

**Use for:** Quick health check — one glance tells you if all three services are healthy.

**Key panels:**
```promql
# Request rate
sum(rate(order_requests_total[5m]))

# Error rate %
sum(rate(order_requests_total{status=~"5.."}[5m])) /
sum(rate(order_requests_total[5m])) * 100
```

---

### Dashboard 2: Microservices Complete (`dashboard-microservices-complete.json`)

**What it shows:**
- Deep-dive into all three services with per-endpoint breakdown
- Latency percentiles: P50, P90, P95, P99
- Error breakdown by type
- Database query latency (simulated)
- Payment decline rate
- Inventory out-of-stock rate

**Use for:** Debugging a specific service issue.

---

### Dashboard 3: SLO Dashboard (`dashboard-slo.json`)

**What it shows:**
- SLO compliance per service (target: 99.9%)
- Error budget remaining (as % and time)
- Burn rate indicators (14.4x / 6x / 3x / 1x)
- Availability timeline (last 30 days)

**The most important dashboard** for an SRE. If error budget remaining drops below 25%, it's time to stop feature work and focus on reliability.

**Key panels:**
```promql
# Error budget remaining
slo:order_service:error_budget_remaining

# Current availability
slo:order_service:availability_rate1h

# 14.4x burn rate indicator (critical threshold)
slo:order_service:error_rate5m > (14.4 * 0.001)
```

---

### Dashboard 4: Endpoints Dashboard (`dashboard-endpoints.json`)

**What it shows:**
- Per-endpoint request rates and latencies
- Heatmap of request duration distribution
- Top slow endpoints
- Status code breakdown per endpoint

**Use for:** Identifying which specific API endpoint is causing latency issues.

---

### Dashboard 5: DORA Metrics (`dashboard-dora.json`)

**What it shows:**
DORA (DevOps Research and Assessment) metrics measure engineering velocity:
- **Deployment Frequency**: How often do we deploy? (From ArgoCD sync events)
- **Lead Time for Changes**: Time from commit to production
- **Change Failure Rate**: % of deployments that cause an incident
- **Time to Restore Service**: Mean time to recovery

**Why DORA matters:** These four metrics are the strongest predictors of software delivery performance. Elite teams deploy multiple times per day, lead time < 1 hour, change failure rate < 5%, MTTR < 1 hour.

---

### Dashboard 6: Cost Dashboard (`dashboard-cost.json`)

**What it shows:**
- Namespace cost breakdown (from OpenCost)
- Cost per deployment
- Resource efficiency (requested vs actual usage)
- Cost trend over time
- Top spenders by namespace

**Example insight:** "The monitoring namespace (Prometheus, Grafana, Loki, Tempo) costs $4.20/day — 35% of total cluster cost. Consider adjusting retention settings."

---

### Dashboard 7: Compliance Dashboard (`dashboard-compliance.json`)

**What it shows:**
- Kyverno policy violations by type
- Falco security events over time
- Pod security context compliance
- Image signature verification failures
- Resource limit coverage

**Use for:** Security posture review. Regulators want to see that security policies are enforced, monitored, and trending toward zero violations.

---

### Dashboard 8: Falco Events (via `falco-servicemonitor.yaml`)

**What it shows:**
- Falco alert rate over time
- Alert breakdown by rule (shell exec, file read, network connection)
- High-severity events requiring immediate investigation

---

## Hands-on Labs

### Lab 1: Find a Slow Request End-to-End

```bash
# Step 1: Generate some traffic
kubectl port-forward svc/order-service 8000:8000 -n apps &
for i in $(seq 1 20); do
  curl -s -X POST http://localhost:8000/orders \
    -H "Content-Type: application/json" \
    -d '{"item_id":"item-1","quantity":1,"customer_id":"test"}' \
    -o /dev/null
done

# Step 2: In Grafana, open Explore → Tempo → Search
# Service: order-service
# Min Duration: 50ms
# Run query → click the slowest trace

# Step 3: In the trace waterfall, find which downstream call was slow

# Step 4: Click "Logs" button → see exact log lines for that request

# Step 5: Copy the trace ID → search in Loki:
# {namespace="apps"} | json | trace_id="<paste-here>"
```

### Lab 2: Trigger an Alert

```bash
# Step 1: Scale order-service to 0 to simulate an outage
kubectl scale deployment order-service -n apps --replicas=0

# Step 2: Watch error rate spike in Grafana → Services Overview

# Step 3: Check Alertmanager at https://alertmanager.yourdomain.com
# You'll see OrderServiceErrorBudgetBurnCriticalFast firing

# Step 4: Restore
kubectl scale deployment order-service -n apps --replicas=2
```

### Lab 3: Query Logs Across Services for One Request

```bash
# Make a request and note the response order_id
curl -s -X POST http://localhost:8000/orders \
  -H "Content-Type: application/json" \
  -d '{"item_id":"item-5","quantity":3,"customer_id":"debug-user"}'
# Response: {"order_id": "ord-abc123", ...}

# In Grafana Explore → Loki:
{namespace="apps"} |= "ord-abc123"
# See logs from order-service AND payment-service AND inventory-service
# all containing the same order ID — end-to-end view of one request
```

---

## Interview Questions — Observability

**Q1: What's the difference between a gauge, counter, and histogram in Prometheus?**
> *Answer:* "A counter only goes up — it tracks cumulative events like total requests or total errors. You use `rate()` to get events per second. A gauge goes up and down — it represents a current state like active connections, memory usage, or pod count. A histogram samples observations into pre-defined buckets and tracks count + sum — used for latency. You use `histogram_quantile(0.95, ...)` to get P95 latency. The key insight is you can't take a percentile of gauges — you need histograms for latency SLOs."

**Q2: What's the difference between distributed tracing and logging?**
> *Answer:* "Logs are individual timestamped events — each log line is independent. Tracing connects related events across multiple services into a single request journey. A log says 'payment failed at 10:30:15'. A trace shows 'the POST /orders request at 10:30:15 called inventory-service (12ms), then payment-service (18ms), and payment returned 402 because the card was declined' — with timing for each hop. Tracing is essential for microservices debugging because a single user request touches 3-10 services, and logs alone can't show you the causal chain."

**Q3: Why use Loki instead of Elasticsearch for logs?**
> *Answer:* "Loki doesn't index log content — only labels. This makes it 10-50x cheaper per GB of logs. For typical Kubernetes debugging (find all errors from service X in the last hour), LogQL with regex filtering on compressed chunks is fast enough. Elasticsearch indexes every word, enabling millisecond full-text search across years of logs — necessary for compliance requirements or complex investigations, but expensive. For this platform, Loki is the right choice because we're doing reactive debugging, not compliance archiving."

**Q4: How do you correlate a Grafana Tempo trace to its Loki logs?**
> *Answer:* "Two mechanisms: First, the OTEL SDK (injected by the OTEL Operator) automatically adds `trace_id` and `span_id` as structured log fields. Loki stores these as searchable labels. Second, Grafana's 'derived fields' feature in the Loki datasource config creates a clickable link from any log line containing a trace_id to the corresponding Tempo trace. In Tempo's UI, there's a 'Logs' button per trace that constructs the LogQL query `{namespace=\"apps\"} | json | trace_id=\"abc123\"`. This lets you jump between trace and logs in one click."

**Q5: How does the OpenTelemetry Collector improve the observability architecture?**
> *Answer:* "Without a Collector, every service sends traces directly to Tempo. This creates tight coupling — if Tempo is down, the service must buffer traces itself (or drop them). The Collector adds a buffer layer: services send to the Collector (which is very lightweight), the Collector batches and forwards to Tempo. If Tempo is temporarily unavailable, the Collector buffers. More importantly, the Collector lets you change backends without touching services: swap from Tempo to Jaeger by changing one Collector config line. You can also add processors — sampling to reduce cost, attribute enrichment to add environment labels, or fan-out to multiple backends simultaneously."

---

## What's Next?

→ **[08-security-compliance.md](08-security-compliance.md)** — Security layers that protect what you're observing
→ **[10-slos-alerting.md](10-slos-alerting.md)** — How Prometheus recording rules and burn-rate alerts are built on top of these metrics
→ **[14-chaos-load-testing.md](14-chaos-load-testing.md)** — Use Grafana, Loki, and Tempo together while running chaos scenarios
