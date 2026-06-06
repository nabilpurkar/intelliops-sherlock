# Chaos Engineering & Load Testing Guide

> **What you'll learn:** How to use Locust to generate realistic and chaos traffic, how to deliberately trigger every type of alert, how to watch what's happening in real time across all tools, and how to interpret what you see.

---

## Why Chaos Engineering?

> "Chaos engineering is the discipline of experimenting on a system in order to build confidence in the system's capability to withstand turbulent conditions in production." — Principles of Chaos Engineering (Netflix)

You can't know if your observability, alerting, and AIOps pipeline works until you deliberately break things and verify that:
1. Prometheus detects the anomaly within the right window
2. The correct alert fires (not too early, not too late)
3. AIOps receives the SQS message
4. Claude correctly diagnoses the root cause
5. Remediation executes and the system recovers

This project has chaos endpoints built into every service for exactly this purpose.

---

## Locust — Load Generator

### What Is Locust?

> "Locust is an easy-to-use, distributed, user load testing tool. It is intended for load testing websites/services and figuring out how many concurrent users a system can handle." — locust.io

**Why Locust over JMeter/k6?**
- Pure Python — test scenarios are real Python code, not XML or JS DSL
- Beautiful web UI to control users in real time
- Tag-based test selection: run only `@tag("chaos")` tasks without changing code
- Built-in Prometheus metrics export for load test visibility in Grafana

### Accessing Locust

```bash
# Option 1: Via ingress (if DNS is configured)
https://locust.yourdomain.com

# Option 2: Port-forward (always works)
kubectl port-forward svc/locust 8089:8089 -n locust
# Open: http://localhost:8089
```

### Locust Web UI Walkthrough

```
1. Number of users: 10       ← Total concurrent virtual users
2. Spawn rate: 1             ← Add 1 user per second until target reached
3. Host: (auto-configured)   ← Points at order-service
4. Click "Start swarming"

5. Watch the charts:
   - RPS (requests per second) — load being generated
   - Response time chart — P50, P95 percentiles
   - Failures — 5xx responses per second

6. Click "Stop" — all users stop immediately
```

---

## Load Testing Scenarios

### Scenario 1: Normal Baseline Traffic

**Goal:** Establish baseline metrics — what does healthy look like?

```bash
# Web UI: 10 users, spawn rate 1, run 5 minutes
# Or headless:
kubectl exec -n locust deploy/locust -- \
  locust --headless -u 10 -r 1 --run-time 5m \
  --tags normal
```

**What to watch:**
- Grafana → Services Overview: ~10 req/s, ~2% error rate, P95 < 100ms
- Grafana → SLO Dashboard: burn rate ≈ 1x (healthy — not burning budget)
- Grafana → Explore → Tempo: multi-service traces appearing

---

### Scenario 2: High Load (Stress Test)

**Goal:** Find where the system starts to degrade — triggers HPA scaling.

```bash
kubectl exec -n locust deploy/locust -- \
  locust --headless -u 100 -r 10 --run-time 10m \
  --tags normal
```

**What to watch:**
- `kubectl get hpa -n apps -w` — replicas increasing as CPU rises
- `kubectl get nodes` — Cluster Autoscaler may add a node
- Grafana → Services Overview: latency rising, eventually stabilizing as pods scale
- CloudWatch → `/aws/eks/intelliops-dev/cluster` → scheduler events

**Expected result:** HPA scales order-service from 2 → 4 replicas, latency stabilizes.

---

### Scenario 3: Pure Chaos Run

**Goal:** Trigger every alert type to validate the AIOps pipeline.

```bash
kubectl exec -n locust deploy/locust -- \
  locust --headless -u 5 -r 1 --run-time 5m \
  --tags chaos
```

**What happens during chaos run:**
1. ChaosUser tasks fire at random — CPU spikes, memory grows, latency injected
2. Circuit breaker opens for 30s periods — payment 503 errors
3. Inventory stock drains — low stock alert fires
4. Cascade timeout traces appear in Tempo
5. AIOps anomaly detector notices spikes → sends to SQS
6. AI agent queries Prometheus + Loki context → calls Bedrock
7. Claude generates remediation plan → Slack notification

---

### Scenario 4: Error Budget Drain Test

**Goal:** Watch the error budget drain in real time on the SLO dashboard.

```bash
# Direct curl — no Locust needed
kubectl port-forward svc/order-service 8000:8000 -n apps &

# Inject 80% error rate for 2 minutes
for i in $(seq 1 200); do
  curl -s "http://localhost:8000/error?rate=80" -o /dev/null
  sleep 0.5
done
```

**What to watch:**
- Grafana → SLO Dashboard → `slo:order_service:error_rate5m` rising
- Grafana → SLO Dashboard → `slo:order_service:error_budget_remaining` dropping
- Alertmanager → `OrderServiceErrorBudgetBurnCriticalFast` fires after 2 min
- Slack → AI agent notification with analysis

**The math:**
- Normal error budget burn: 2% error rate = 20x burn → budget exhausts in ~36 hours
- 80% error rate = 800x burn → budget exhausts in minutes
- SLO alert threshold is 14.4x → fires almost immediately

---

### Scenario 5: Circuit Breaker Cascade Test

**Goal:** Test that a payment service failure causes observable cascade in order-service.

```bash
# Step 1: Open circuit breaker
kubectl exec -n apps deploy/payment-service -- \
  curl -s -X POST "http://localhost:8002/chaos/circuit-open?duration=60"
# OR via port-forward:
curl -X POST "http://localhost:8002/chaos/circuit-open?duration=60"

# Step 2: Send orders while circuit is open
for i in $(seq 1 20); do
  curl -s -X POST http://localhost:8000/orders
done
# All orders fail because payment-service returns 503

# Step 3: Close early
curl -X POST "http://localhost:8002/chaos/circuit-close"
```

**What to watch:**
- Tempo: traces showing `payment-service → 503` as child span
- Prometheus: `payment_circuit_breaker_open == 1`, `payment_requests_total{status="503"}` rising
- Grafana: cascading error rate in both payment AND order service

---

### Scenario 6: Memory Leak Simulation

**Goal:** Verify memory monitoring detects gradual memory growth before OOMKill.

```bash
# Step 1: Allocate 50MB every 30 seconds
for mb in 50 100 150 200 250; do
  curl -s "http://localhost:8000/stress/memory?mb=50"
  sleep 30
  echo "Total leaked: $((mb)) MB"
done

# Step 2: Watch memory grow
kubectl top pods -n apps | grep order-service

# Step 3: Release
curl http://localhost:8000/stress/memory/reset
```

**What to watch:**
- `order_memory_leak_bytes` metric rising: 52MB → 104MB → 156MB → 208MB → 260MB
- Grafana → Services Overview: memory usage rising toward 512Mi limit
- AlertManager: `memory: averageUtilization 70%` → HPA fires
- If limit hit → pod OOMKilled → CrashLoopBackOff → ArgoCD shows Degraded

---

### Scenario 7: Disk I/O Saturation

**Goal:** Saturate disk I/O on inventory-service.

```bash
# Write 50 files × 1MB = 50MB of writes
curl "http://localhost:8001/stress/disk/write?files=50&size_kb=1024"

# Read them all back
curl "http://localhost:8001/stress/disk/read?files=50"

# Cleanup
curl -X DELETE http://localhost:8001/stress/disk/cleanup
```

**What to watch:**
- `inventory_disk_write_secs` histogram: bucket values shifting right (slower writes)
- Node disk I/O: `node_disk_io_time_seconds_total` rising in Grafana

---

## Where to Check What Is Happening

This is the master reference for "I triggered chaos — where do I look?"

### Real-Time Cluster State

```bash
# All pods — is everything Running?
kubectl get pods -A

# Non-healthy pods only
kubectl get pods -A | grep -v Running | grep -v Completed

# Watch pods change in real time (e.g., during HPA scale)
kubectl get pods -n apps -w

# HPA state — replicas and utilization
kubectl get hpa -n apps
# TARGETS column shows current vs threshold

# Recent events — what Kubernetes just did
kubectl get events -n apps --sort-by='.lastTimestamp' | tail -20

# Node resources
kubectl top nodes

# Pod resources
kubectl top pods -n apps
```

---

### Prometheus — Metrics

**URL:** `https://prometheus.yourdomain.com` or `kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring`

**Key queries to run immediately after triggering chaos:**

```promql
# Current error rate for all services
sum(rate(order_requests_total{status=~"5.."}[1m])) /
sum(rate(order_requests_total[1m]))

# Is circuit breaker open?
payment_circuit_breaker_open

# Memory leaked in order-service
order_memory_leak_bytes

# CPU stress active
order_cpu_stress_active

# Low stock alert status
inventory_low_stock_items

# Current burn rates (should be < 1 normally)
slo:order_service:error_rate5m / 0.001
slo:payment_service:error_rate5m / 0.001
slo:inventory_service:error_rate5m / 0.001

# Error budget remaining (1 = full, 0 = exhausted)
slo:order_service:error_budget_remaining
```

**Prometheus UI tabs:**
- **Graph**: Run PromQL, see time series
- **Status → Targets**: Is Prometheus scraping your services? (Green = yes, Red = error)
- **Status → Rules**: Are recording rules evaluated? Any evaluation errors?
- **Alerts**: Which alerts are FIRING vs PENDING vs inactive?

---

### Alertmanager — Active Alerts

**URL:** `https://alertmanager.yourdomain.com` or `kubectl port-forward svc/kube-prometheus-stack-alertmanager 9093:9093 -n monitoring`

**What you see:**
```
Group: order-service
  [FIRING] OrderServiceErrorBudgetBurnCriticalFast
    severity: critical
    Firing since: 2 minutes ago
    Value: 14.7x burn rate
    Description: At this rate monthly budget exhausts in 2 hours
```

**Silence an alert** (during planned chaos testing):
1. Click the alert
2. Click "Silence"
3. Set duration (e.g., 1 hour)
4. Add comment: "Planned chaos test"

This prevents on-call pages during intentional testing.

---

### Grafana — Dashboards & Explore

**URL:** `https://grafana.yourdomain.com`

**Dashboard sequence during a chaos test:**

1. **Services Overview** (`/d/services`)
   - First place to look: real-time RPS, error rate, latency per service
   - Spike immediately visible as bars turn red

2. **SLO Dashboard** (`/d/slo`)
   - Error budget remaining number
   - Burn rate gauge: green (<1x) → yellow (3-6x) → red (>14.4x)

3. **Microservices Complete** (`/d/microservices-complete`)
   - Per-endpoint breakdown — which specific endpoint is affected?
   - Chaos metrics: `order_memory_leak_bytes`, `payment_circuit_breaker_open`

4. **Compliance Dashboard** (`/d/compliance`)
   - Falco events: did chaos trigger any kernel-level security rules?
   - Kyverno violations

**Grafana Explore — Logs:**
```logql
# Find all errors in the last 5 minutes
{namespace="apps"} |= "error" | json

# Find logs from the chaos user test
{namespace="locust"} | json

# Find all logs for a specific chaos operation
{namespace="apps"} |= "injected failure"
```

**Grafana Explore — Traces:**
1. Select Tempo datasource
2. Service Name: `order-service`
3. Set Min Duration: `1s` (to find chaos-slow requests)
4. Click a trace → waterfall shows which downstream call was slow/failed
5. Click "Logs" → jumps to Loki logs for that exact request

---

### ArgoCD — Deployment Health

**URL:** `https://argocd.yourdomain.com`

**What to check during/after chaos:**
- Application status: `Synced + Healthy` = good, `Degraded` = pods not healthy
- Click into an application → tree view shows exact pod status
- If a pod OOMKills, ArgoCD shows it as Degraded until new pod starts
- Recent sync history: did a CI deployment happen that might explain the issue?

```bash
# CLI equivalent
argocd app list
argocd app get microservices
kubectl describe application microservices -n argocd
```

---

### AWS Console — What's Happening at Infrastructure Level

**EKS Console** → Clusters → intelliops-dev → Compute tab
- Node group: see current node count (Cluster Autoscaler activity)
- If chaos caused HPA to scale pods and nodes were full → new node appears here

**CloudWatch** → Log Insights → `/aws/eks/intelliops-dev/cluster`
```sql
-- Who ran kubectl scale recently?
fields @timestamp, user.username, objectRef.resource, verb
| filter verb = "patch" and objectRef.resource = "deployments"
| sort @timestamp desc
| limit 10

-- Was there a node added by Cluster Autoscaler?
fields @timestamp, level, msg
| filter level = "info" and msg like "scale-up"
| sort @timestamp desc
```

**EC2 Console** → Instances → Filter by `eks:cluster-name = intelliops-dev`
- During Cluster Autoscaler activity: new instance in `pending` or `initializing` state

**SQS Console** → intelliops-anomalies queue
- ApproximateNumberOfMessages: should be 0 (AI agent consumed them)
- If > 0: AI agent is behind or crashed

**Bedrock Console** → Model invocations (not always visible without CloudTrail)
- Check CloudTrail → Event history → Event source `bedrock.amazonaws.com`
- InvokeModel events show when AI agent called Claude

---

### Slack — AIOps Notifications

During chaos tests, the AI agent sends messages to your Slack channel configured in `intelliops/dev/slack` secret. Each message contains:

```
🚨 AIOps Alert: order-service anomaly detected
Service: order-service
Anomaly: Error rate 4.5% (baseline 2%)
Correlation: Also affects payment-service (503s)
Root Cause: Likely circuit breaker cascade — payment returned 503 → order failed
Confidence: High
Remediation:
  1. Check circuit breaker state: payment_circuit_breaker_open == 1
  2. Close circuit breaker: POST /chaos/circuit-close
  3. Monitor: error rate should normalize in 2-3 minutes
Actions taken: None (manual approval mode)
```

---

### Falco — Runtime Security Events

Falco alerts appear in:
1. **Grafana → Compliance Dashboard** — event count over time
2. **Slack** — if Falco sidekick is configured
3. **Pod logs**: `kubectl logs -n falco daemonset/falco`

**Chaos operations that trigger Falco:**
- `kubectl exec` into a pod → "Terminal shell in container" rule
- CPU stress writing to system files → potential "Write below etc" if path drifted
- Disk stress in inventory → "Large file written" rule (if Falco has this custom rule)

```bash
# Watch Falco events in real time
kubectl logs -n falco daemonset/falco -f | grep -E "WARNING|ERROR|CRITICAL"
```

---

## Quick Chaos Playbook

### Run a Full AIOps Demo in 10 Minutes

```bash
# Port-forward everything
kubectl port-forward svc/order-service     8000:8000 -n apps &
kubectl port-forward svc/payment-service   8002:8002 -n apps &
kubectl port-forward svc/inventory-service 8001:8001 -n apps &

# Step 1: Open Grafana → Services Overview (keep this visible)

# Step 2: Trigger 3 chaos scenarios simultaneously
curl -X POST "http://localhost:8002/chaos/circuit-open?duration=120" &
curl "http://localhost:8001/chaos/stock-drain" &
curl "http://localhost:8000/stress/cpu?duration=30" &

# Step 3: Generate traffic to see it in metrics
for i in $(seq 1 100); do
  curl -s -X POST http://localhost:8000/orders -o /dev/null
  sleep 0.2
done

# Step 4: Watch in parallel:
#   - Grafana Services Overview: red bars appearing
#   - Alertmanager: PaymentServiceErrorBudgetBurnCriticalFast firing
#   - kubectl logs -n aiops-demo deployment/ai-agent -f
#   - Slack: AI agent notification

# Step 5: Restore
curl -X POST "http://localhost:8002/chaos/circuit-close"
curl "http://localhost:8001/chaos/stock-restore"

# Step 6: Watch metrics normalize over 2-3 minutes
```

---

## All Service URLs Quick Reference

| Service | URL | Credentials | Notes |
|---------|-----|-------------|-------|
| **Grafana** | https://grafana.yourdomain.com | admin / see INSTRUCTIONS.md | 8 dashboards pre-loaded |
| **Prometheus** | https://prometheus.yourdomain.com | None | Direct PromQL access |
| **AlertManager** | https://alertmanager.yourdomain.com | None | Active alerts + silences |
| **ArgoCD** | https://argocd.yourdomain.com | admin / see INSTRUCTIONS.md | GitOps status |
| **SonarQube** | https://sonarqube.yourdomain.com | admin / see INSTRUCTIONS.md | Code quality |
| **DefectDojo** | https://defectdojo.yourdomain.com | admin / see INSTRUCTIONS.md | Security findings |
| **Backstage** | https://backstage.yourdomain.com | None (guest) | Developer portal |
| **Kong Admin** | https://kong-admin.yourdomain.com | None | API gateway management |
| **Locust** | https://locust.yourdomain.com | None | Load testing UI |
| **Apps API** | https://apps.yourdomain.com | None | /orders /payments /inventory |

All passwords are in `INSTRUCTIONS.md` (generated by `configure-stack.sh`).

To see them at any time:
```bash
cat INSTRUCTIONS.md
# Or get individual passwords from SM:
aws secretsmanager get-secret-value --secret-id intelliops/dev/grafana \
  --query SecretString --output text | jq -r .admin_password
```

---

## Interview Questions — Chaos Engineering & Load Testing

**Q1: What is chaos engineering and how do you do it safely?**
> *Answer:* "Chaos engineering is deliberately injecting failures — latency, errors, resource exhaustion — to verify the system handles them gracefully. Safety comes from three controls: blast radius limiting (chaos endpoints only affect their own service, not the whole cluster), reversibility (all chaos endpoints have reset endpoints — circuit-close, stock-restore, memory-reset), and observability first (we set up Grafana, alerting, and Slack notifications before running chaos so we can see what's happening and know when to stop). We also run chaos in dev only, never production, without explicit approval."

**Q2: How does the circuit breaker pattern prevent cascade failures?**
> *Answer:* "Without a circuit breaker: if payment-service is slow, every order-service request waits 2 seconds (the timeout) before failing — tying up threads. Under load, all threads are waiting for payment, so new requests queue up, order-service becomes unresponsive, and Kong's load balancer gets timeout errors too. The whole platform goes down because of one slow downstream. With a circuit breaker: after N failures in a time window, the breaker opens. Subsequent requests fail immediately (no waiting) with 503. Order-service stays responsive, it just tells clients 'payment unavailable'. After a timeout, the breaker tries one request (half-open) — if it succeeds, the breaker closes."

**Q3: You're on call. At 3am you get a page: OrderServiceErrorBudgetBurnCriticalFast. Walk me through your investigation.**
> *Answer:* "First: Grafana → Services Overview. Is this just order-service or all three? If all three, it's an infrastructure issue (node, network). If just order-service, something specific to it. Second: what changed recently? ArgoCD → microservices → recent syncs. Was there a deployment 15 minutes ago? Check the image tag in the sync. Third: Grafana Explore → Tempo → order-service → filter by status=error — what's the error? Is it downstream (payment 503) or internal (order-service itself)? Check if payment_circuit_breaker_open is 1. Fourth: check the AI agent's Slack message — it already gathered this context and suggested remediation. Fifth: verify the fix by watching the error rate normalize on the SLO dashboard. Total time: under 5 minutes with this tooling."

**Q4: How do you generate realistic load in a microservices environment?**
> *Answer:* "Realistic means two things: realistic traffic patterns and realistic service calls. Locust's `NormalUser` class (80% of users) creates orders that fan out to inventory and payment — so we generate real distributed traces, not just synthetic HTTP hits. The think time `between(0.5, 2.0)` simulates real user behavior gaps. We separate normal users from `ChaosUser` (20%) using Locust's `@tag` decorator and `weight` — you can run only normal traffic with `--tags normal` or only chaos with `--tags chaos`. For load tests, we start with 10 users to establish baseline, then ramp to 100 to find the scaling threshold, then back to 10 to verify recovery — this mimics real traffic patterns."
