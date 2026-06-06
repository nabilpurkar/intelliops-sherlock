# Microservices & APIs Guide

> **What you'll learn:** How the three FastAPI services are designed, every API endpoint including chaos endpoints, what Prometheus metrics each exposes, how OTEL auto-instrumentation works without code changes, and how to extend the services.

---

## Overview

Three microservices simulate a real e-commerce backend. Each service has two endpoint groups: **business endpoints** (normal traffic) and **chaos endpoints** (for triggering AIOps signals).

```
┌──────────────────────────────────────────────────────────────────┐
│  Client (Locust / curl / browser)                                 │
│       │                                                            │
│       ▼                                                            │
│  Kong → order-service:8000                                        │
│              │                                                     │
│              ├──► inventory-service:8001 (check stock)            │
│              └──► payment-service:8002  (process payment)         │
│                                                                    │
│  All three: Prometheus /metrics + OTEL traces (auto-inject)       │
│  All three: /slow, /error, /stress/* chaos endpoints              │
└──────────────────────────────────────────────────────────────────┘
```

**Why these services?** They create realistic inter-service dependencies (fan-out pattern), synthetic errors at known rates, and emit the Prometheus metrics that the SLO rules and AIOps pipeline depend on. The chaos endpoints let you deliberately trigger every type of alert to see the full AIOps remediation flow.

---

## Order Service

**Port:** 8000 | **Image:** `intelliops-dev/order-service` | **Namespace:** `apps`

### What It Does
The entry-point service. Receives orders, calls inventory to check stock, calls payment to process, records the result. Base error rate ~2%.

### Business API Endpoints

| Method | Path | Description | Response |
|--------|------|-------------|----------|
| `GET` | `/health` | Liveness check | `{"status":"ok","service":"order-service"}` |
| `GET` | `/ready` | Readiness check | `{"status":"ready"}` |
| `GET` | `/metrics` | Prometheus exposition | text/plain |
| `POST` | `/orders` | Create new order — calls inventory + payment | 201 or 500 |
| `GET` | `/orders/{order_id}` | Get order status | Order object or 404 |
| `GET` | `/downstream/call` | Normal fan-out to both services — generates multi-service trace | JSON |

### Chaos API Endpoints

| Method | Path | Query Params | Effect | AIOps Signal |
|--------|------|-------------|--------|--------------|
| `GET` | `/stress/cpu` | `?duration=10` (1-60s) | Burns CPU in background thread | CPU spike → node CPU alert |
| `GET` | `/stress/memory` | `?mb=50` (1-500MB) | Allocates and holds memory | `order_memory_leak_bytes` rises → OOMKill risk |
| `GET` | `/stress/memory/reset` | — | Releases all held memory | Memory drops |
| `GET` | `/slow` | `?delay=2000` (ms) | Sleeps N ms before responding | Latency SLO breach |
| `GET` | `/error` | `?rate=50` (0-100%) | Returns 500 with N% probability | Error budget burn |
| `GET` | `/downstream/timeout` | — | Forces timeout calling inventory-service | Cascade failure trace |

### Request/Response Schema
```json
// POST /orders — no body required (demo service)
// Response 200 (success):
{"order_id": 4721, "status": "created"}

// Response 500 (~2% rate):
{"error": "payment declined"}
```

### Prometheus Metrics

```prometheus
# Total requests with labels
order_requests_total{method="POST", endpoint="/orders", status="200"} 847

# Latency histogram (0.005s → 2.5s buckets)
order_request_duration_seconds_bucket{le="0.1", endpoint="/orders"} 821
order_request_duration_seconds_count{endpoint="/orders"} 847
order_request_duration_seconds_sum{endpoint="/orders"} 42.3

# Business metrics
orders_created_total{status="success"} 830
orders_created_total{status="failed"} 17
orders_active_total 3                          # Gauge — current in-flight

# Error breakdown
order_errors_total{error_type="payment_declined"} 17
order_errors_total{error_type="injected"} 5
order_errors_total{error_type="timeout"} 2

# DB query latency (simulated)
db_query_duration_seconds_bucket{query_type="insert", le="0.05"} 843
db_query_duration_seconds_bucket{query_type="select", le="0.05"} 761

# Chaos metrics (0 when inactive)
order_memory_leak_bytes 52428800               # 50MB leaked
order_cpu_stress_active 1                      # 1 = stress running
```

### Key PromQL Queries
```promql
# Error rate (used by SLO rules)
sum(rate(order_requests_total{status=~"5.."}[5m])) / sum(rate(order_requests_total[5m]))

# P99 latency
histogram_quantile(0.99, rate(order_request_duration_seconds_bucket[5m]))

# Is memory leak active?
order_memory_leak_bytes > 0

# CPU stress gauge
order_cpu_stress_active
```

### Service-to-Service Calls
```python
# In create_order() — calls both downstream services in parallel
async with httpx.AsyncClient(timeout=2.0) as client:
    await client.get(f"{INVENTORY_URL}/inventory/check")  # → child span in trace
    await client.post(f"{PAYMENT_URL}/payments/process")  # → child span in trace
```

The OTEL SDK wraps `httpx` calls and injects W3C `traceparent` headers automatically — downstream services pick up the trace ID and create child spans.

---

## Payment Service

**Port:** 8002 | **Image:** `intelliops-dev/payment-service` | **Namespace:** `apps`

### What It Does
Simulates a payment processor with realistic latency (5-25ms), 1.5% decline rate, 0.5% fraud detection rate, and a controllable circuit breaker for chaos testing.

### Business API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Liveness check |
| `GET` | `/ready` | Readiness check |
| `GET` | `/metrics` | Prometheus exposition |
| `POST` | `/payments/process` | Process payment — called by order-service |
| `POST` | `/payments/{order_id}` | Process payment for specific order |

### Chaos API Endpoints

| Method | Path | Query Params | Effect | AIOps Signal |
|--------|------|-------------|--------|--------------|
| `POST` | `/chaos/circuit-open` | `?duration=60` (5-300s) | Opens circuit breaker — all payments return 503 | Payment error rate spikes → SLO alert |
| `POST` | `/chaos/circuit-close` | — | Closes circuit breaker early | Recovery trace |
| `GET` | `/slow` | `?delay=2000` (ms) | Slow gateway simulation | P99 latency alert |
| `GET` | `/error` | `?rate=50` (0-100%) | Returns 500 with N% probability | Error budget burn |
| `GET` | `/chaos/retry-storm` | `?count=20` (1-100) | Increments retry counter N times | `payment_retries_total` spike |

### Prometheus Metrics

```prometheus
# Requests
payment_requests_total{method="POST", endpoint="/payments/process", status="200"} 829
payment_requests_total{method="POST", endpoint="/payments/process", status="402"} 12
payment_requests_total{method="POST", endpoint="/payments/process", status="503"} 5  # circuit open

# Note: _secs suffix (not _seconds) — intentional, matches SLO rule names
payment_request_duration_secs_bucket{le="0.025"} 820
payment_request_duration_secs_count 841

# Business metrics
payments_processed_total{result="success"} 816
payments_processed_total{result="declined"} 12
payments_processed_total{result="fraud"} 4

# Gateway latency (separate from request latency)
payment_gateway_latency_secs_bucket{le="0.025"} 810

# Chaos metrics
payment_circuit_breaker_open 1       # 1 = circuit open, 0 = closed
payment_retries_total 47             # cumulative retries
payment_fraud_detected_total 4       # fraud detections
payment_errors_total{error_type="circuit_open"} 5
```

### Key PromQL Queries
```promql
# Payment success rate
rate(payments_processed_total{result="success"}[5m])

# Is circuit breaker open?
payment_circuit_breaker_open == 1

# Retry rate (elevated = retry storm or upstream issues)
rate(payment_retries_total[5m])

# Fraud detection rate
rate(payment_fraud_detected_total[5m])

# P99 gateway latency
histogram_quantile(0.99, rate(payment_gateway_latency_secs_bucket[5m]))
```

---

## Inventory Service

**Port:** 8001 | **Image:** `intelliops-dev/inventory-service` | **Namespace:** `apps`

### What It Does
Simulates inventory management — returns stock counts with a simulated cache layer (85% hit rate) and disk I/O for chaos testing. Base 0.5% out-of-stock 404 rate.

### Business API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Liveness check |
| `GET` | `/ready` | Readiness check |
| `GET` | `/metrics` | Prometheus exposition |
| `GET` | `/inventory/check` | Check stock — 85% cache hit, 15% slower DB path |
| `GET` | `/inventory/{item_id}` | Get specific item details |

### Chaos API Endpoints

| Method | Path | Query Params | Effect | AIOps Signal |
|--------|------|-------------|--------|--------------|
| `GET` | `/stress/disk/write` | `?files=10&size_kb=512` | Write stress files to /tmp | Disk I/O saturation |
| `GET` | `/stress/disk/read` | `?files=10` | Read all stress files from /tmp | Disk read latency |
| `DELETE` | `/stress/disk/cleanup` | — | Delete all stress temp files | — |
| `GET` | `/chaos/stock-drain` | — | Set all 20 items stock = 0 | `inventory_low_stock_items` spikes |
| `GET` | `/chaos/stock-restore` | — | Restore original stock levels | Stock normalizes |
| `GET` | `/slow` | `?delay=2000` (ms) | Slow DB query simulation | P95 latency SLO alert |
| `GET` | `/error` | `?rate=50` (0-100%) | Returns 500 with N% probability | Error budget burn |

### Prometheus Metrics

```prometheus
# Requests
inventory_requests_total{method="GET", endpoint="/inventory/check", status="200"} 1847
inventory_requests_total{method="GET", endpoint="/inventory/{item_id}", status="404"} 9

# Note: _secs suffix — matches SLO rule names
inventory_request_duration_secs_bucket{le="0.005"} 1801
inventory_request_duration_secs_count 1856

# Cache performance
inventory_cache_ops_total{result="hit"} 1572
inventory_cache_ops_total{result="miss"} 275

# Disk I/O (chaos)
inventory_disk_write_secs_bucket{le="0.01"} 45
inventory_disk_write_secs_count 50

# Stock
inventory_low_stock_items 3           # Items below reorder threshold
```

### Key PromQL Queries
```promql
# Cache hit rate (should be ~85%)
rate(inventory_cache_ops_total{result="hit"}[5m])
  / rate(inventory_cache_ops_total[5m])

# P95 disk write latency
histogram_quantile(0.95, rate(inventory_disk_write_secs_bucket[5m]))

# Low stock items gauge
inventory_low_stock_items

# Out of stock error rate
rate(inventory_requests_total{status="404"}[5m])
```

---

## OTEL Auto-Instrumentation (Zero Code Changes)

The services contain **no OpenTelemetry imports** — yet distributed traces appear in Grafana Tempo for every request.

### How It Works

```
k8s/apps/order-service.yaml — pod annotation:
  instrumentation.opentelemetry.io/inject-python: "true"
                  │
                  ▼
  OTEL Operator MutatingAdmissionWebhook intercepts pod creation
  Injects init container: copies Python OTEL SDK to /otel-auto-instrumentation-python
  Sets PYTHONPATH to include that directory
                  │
                  ▼
  Python starts → sitecustomize.py loads automatically via PYTHONPATH
  Instruments: FastAPI (wraps all route handlers with spans)
               httpx   (wraps all outgoing requests with spans)
  Propagates: W3C traceparent header between services
                  │
                  ▼
  Every request → span → OTEL Collector → Tempo → Grafana
```

### What Gets Traced Automatically
- Every HTTP request received (method, URL, status code, duration)
- Every HTTP request sent (downstream calls from httpx)
- W3C TraceContext headers propagated — inventory and payment spans linked to parent order span
- No application code changes required

### Kubernetes Pod Annotation
```yaml
# k8s/apps/order-service.yaml — pod template annotations
annotations:
  instrumentation.opentelemetry.io/inject-python: "true"
```

Same annotation on payment-service and inventory-service pods.

---

## Dockerfile Pattern (All Three Services)

```dockerfile
FROM python:3.12-slim

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Non-root user required by Kyverno require-pod-security-context policy
RUN useradd -u 1000 -m app
USER 1000

WORKDIR /app
COPY main.py .

EXPOSE 8000  # (8001 for inventory, 8002 for payment)

# No opentelemetry-instrument wrapper — OTEL Operator handles injection
CMD ["python3", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

**Security context in Kubernetes** (required by Kyverno `require-pod-security-context` policy):
```yaml
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true    # inventory-service writes to /tmp via emptyDir volume
  runAsNonRoot: true
  runAsUser: 1000
```

The `readOnlyRootFilesystem: true` is why inventory-service's disk stress endpoints write to `/tmp` — there's an emptyDir volume mounted there.

---

## Kubernetes Resource Configuration

### Key Parameters to Change for Your Setup

| Parameter | File | Default | When to Change |
|-----------|------|---------|---------------|
| `image:` ECR URL | `k8s/apps/*.yaml` | `007066145518.dkr.ecr.us-east-1.amazonaws.com/intelliops-dev/…` | Always — replace account ID `007066145518` with your AWS account ID |
| `resources.limits.cpu` | `k8s/apps/*.yaml` | `500m` | Increase if pods are CPU-throttled; check Grafana throttle graph |
| `resources.limits.memory` | `k8s/apps/*.yaml` | `512Mi` | Increase if OOMKilled; decrease to trigger memory chaos faster |
| `minReplicas` / `maxReplicas` | `k8s/apps/*.yaml` HPA section | 2 / 4 | Increase max for higher load capacity; keep min ≥ 2 for HA |
| `averageUtilization` (HPA) | `k8s/apps/*.yaml` | 60% CPU / 70% memory | Lower to scale earlier; raise to scale later |
| `INVENTORY_SERVICE_URL` | `k8s/apps/order-service.yaml` | `…apps.svc.cluster.local:8001` | Only change if you rename namespaces |
| `PAYMENT_SERVICE_URL` | `k8s/apps/order-service.yaml` | `…apps.svc.cluster.local:8002` | Only change if you rename namespaces |
| `HOST` | `k8s/load-generator/locust.yaml` ConfigMap | `http://order-service.apps.svc.cluster.local:8000` | Change if load testing a different service |
| `replicas` (Locust) | `k8s/load-generator/locust.yaml` | 1 | Increase to run Locust distributed (multiple workers) |

> **Tip:** The account ID `007066145518` appears in every image tag. After `terraform apply`, your actual account ID will be in the image tags managed by `configure-stack.sh` and CI/CD — you don't edit these manually in production. For the first manual deploy, find your account ID with `aws sts get-caller-identity --query Account --output text`.

```yaml
resources:
  requests:
    cpu: "100m"      # Scheduler guarantees this much
    memory: "128Mi"
  limits:
    cpu: "500m"      # Hard cap — throttled if exceeded
    memory: "512Mi"  # Hard cap — OOMKilled if exceeded
```

### Health Probes
```yaml
livenessProbe:   # Is the process alive? Kill and restart if fails
  httpGet: { path: /health, port: 8000 }
  initialDelaySeconds: 15
  periodSeconds: 20
  failureThreshold: 3

readinessProbe:  # Is the pod ready to receive traffic? Remove from LB if fails
  httpGet: { path: /ready, port: 8000 }
  initialDelaySeconds: 10
  periodSeconds: 10
  failureThreshold: 3

startupProbe:    # Overrides liveness during slow startup
  httpGet: { path: /health, port: 8000 }
  failureThreshold: 10
  periodSeconds: 5  # 10×5s = 50s max startup time
```

### HPA (Horizontal Pod Autoscaler)
```yaml
minReplicas: 2     # Always at least 2 for HA
maxReplicas: 4
metrics:
  - cpu: averageUtilization: 60    # Scale up when CPU > 60%
  - memory: averageUtilization: 70 # Scale up when memory > 70%
```

### Topology Spread Constraints
```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
```
Spreads pods across nodes so a single node failure doesn't take down all replicas.

---

## Hands-on Lab: Test Chaos Endpoints

```bash
# Port-forward all three services
kubectl port-forward svc/order-service    8000:8000 -n apps &
kubectl port-forward svc/payment-service  8002:8002 -n apps &
kubectl port-forward svc/inventory-service 8001:8001 -n apps &

# ── Normal traffic ────────────────────────────────────────────────
# Create an order (normal path — calls inventory + payment)
curl -s -X POST http://localhost:8000/orders | jq .

# Get a distributed trace (full multi-service call)
curl -s http://localhost:8000/downstream/call | jq .

# ── Trigger CPU spike ─────────────────────────────────────────────
curl http://localhost:8000/stress/cpu?duration=15
# Check Prometheus: order_cpu_stress_active == 1
# Watch in Grafana: Services Overview → order-service CPU

# ── Trigger memory leak ───────────────────────────────────────────
curl http://localhost:8000/stress/memory?mb=100
# Check: order_memory_leak_bytes{} == 104857600
curl http://localhost:8000/stress/memory/reset  # cleanup

# ── Inject high latency ───────────────────────────────────────────
curl "http://localhost:8000/slow?delay=3000"    # 3 second response
# Watch: Grafana → SLO Dashboard → P95 latency spike

# ── Inject errors (burn error budget) ────────────────────────────
for i in $(seq 1 50); do
  curl -s "http://localhost:8000/error?rate=80" -o /dev/null -w "%{http_code} "
done
# ~40 × 500 responses → burns error budget
# Watch: Grafana → SLO Dashboard → error_budget_remaining drops

# ── Open circuit breaker (all payments fail) ─────────────────────
curl -X POST "http://localhost:8002/chaos/circuit-open?duration=30"
# For 30 seconds, POST /payments/process returns 503
# Watch: payment_circuit_breaker_open == 1
curl -X POST http://localhost:8002/chaos/circuit-close  # early close

# ── Drain inventory stock ─────────────────────────────────────────
curl http://localhost:8001/chaos/stock-drain
# inventory_low_stock_items spikes to 20
curl http://localhost:8001/chaos/stock-restore  # restore

# ── Disk I/O stress on inventory ─────────────────────────────────
curl "http://localhost:8001/stress/disk/write?files=20&size_kb=1024"
curl -X DELETE http://localhost:8001/stress/disk/cleanup
```

---

## Interview Questions — Microservices & APIs

**Q1: What's the difference between liveness and readiness probes?**
> *Answer:* "Liveness probes answer 'is this process alive?' — if it fails 3 times, Kubernetes kills and restarts the pod. Readiness probes answer 'is this pod ready for traffic?' — if it fails, the pod is removed from the Service endpoints (load balancer) but not restarted. The startup probe overrides liveness during initial startup, giving slow-starting apps (like those loading ML models) time to initialize without being killed. You need all three because a pod can be alive (process running) but not ready (still loading config), and new pods need more startup time than established ones."

**Q2: How does the OTEL Operator instrument Python services without code changes?**
> *Answer:* "The OTEL Operator runs a MutatingAdmissionWebhook. When a pod is created with the annotation `instrumentation.opentelemetry.io/inject-python: true`, the webhook intercepts the pod spec before it starts. It adds an init container that copies the OpenTelemetry Python SDK into an emptyDir shared volume at `/otel-auto-instrumentation-python`. It sets `PYTHONPATH` to include that path. When Python starts, it automatically loads `sitecustomize.py` via `PYTHONPATH`, which bootstraps the SDK and auto-instruments FastAPI and httpx. Zero application code changes needed."

**Q3: Why is the circuit breaker pattern important for payment services?**
> *Answer:* "Without a circuit breaker, if the payment gateway is slow or failing, every order request waits for the full timeout before failing — tying up threads and connections. With a circuit breaker: after a threshold of failures, the breaker opens and requests fail immediately with 503 instead of waiting. This protects order-service from being blocked by payment-service failures, and gives payment-service time to recover. Our chaos endpoint `/chaos/circuit-open` lets you test that the monitoring stack detects it (payment_circuit_breaker_open = 1) and the AIOps agent recommends the appropriate remediation."

**Q4: Why does payment-service use `_secs` suffix for metrics instead of `_seconds`?**
> *Answer:* "This is intentional — it demonstrates that real-world metric naming isn't always consistent. The SLO recording rules in `k8s/slos/app-slos.yaml` reference `payment_request_duration_secs_bucket` — they were written to match the metric name we chose. If you have existing metrics with naming inconsistencies, changing them breaks all your alerts and dashboards. The fix is to either add a recording rule that aliases the metric or accept the inconsistency. This is a real production scenario where changing metric names has downstream consequences."

---

## What's Next?

→ **[05-cicd-pipeline.md](05-cicd-pipeline.md)** — How service images are built, scanned, signed, and deployed via GitHub Actions
→ **[07-observability.md](07-observability.md)** — How to query these service metrics in Prometheus, Loki, and Grafana
→ **[14-chaos-load-testing.md](14-chaos-load-testing.md)** — Run the chaos endpoints with Locust and observe AIOps detection
