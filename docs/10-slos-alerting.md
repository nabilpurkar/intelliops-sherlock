# SLOs & Alerting Guide

> **What you'll learn:** What SLOs and error budgets are, why multi-window burn-rate alerting is better than simple threshold alerting, how the PrometheusRules in this project implement them, and how to read the SLO dashboard.

---

## Why SLOs Matter

**Without SLOs:** "The API is slow" — how slow? Is it acceptable? Who decides?

**With SLOs:** "We agreed to 99.9% availability. Last month we had 43 minutes of downtime. That's 0.1% error rate — exactly at budget. We have zero budget left for risky changes."

SLOs turn reliability from an opinion into a measurable commitment.

---

## The Three Concepts

### SLI — Service Level Indicator
A measurable quantity of service behavior.

Examples:
- **Availability**: `(successful_requests / total_requests) × 100%`
- **Latency**: `P95 request duration < 500ms`
- **Throughput**: `requests_per_second > 100`

In this project: error rate = `sum(5xx responses) / sum(all responses)`

### SLO — Service Level Objective
The target for an SLI over a time window.

Example: "order-service availability ≥ 99.9% over 30 days"

This project's SLOs:
- order-service: 99.9% availability, P95 latency < 500ms
- payment-service: 99.9% availability, P95 latency < 500ms
- inventory-service: 99.9% availability, P95 latency < 300ms

### Error Budget
The allowed amount of "bad" outcomes within the SLO.

```
99.9% SLO over 30 days:
  Total requests: 1,000,000
  Allowed errors: 1,000,000 × 0.001 = 1,000 errors
  Allowed downtime: 30 days × 24h × 60min × 0.001 = 43.2 minutes
```

If you've used 80% of your error budget halfway through the month, you're burning too fast and should slow down risky deployments.

---

## Multi-Window Burn-Rate Alerting

Simple threshold alerting is broken: `alert if error_rate > 1%` fires too many false positives (short spikes) and misses slow-burn problems (0.2% for 3 days = exhausted budget).

**The Google SRE Book solution:** Multi-window, multi-burn-rate alerts.

### The Four Alert Windows

```
Error budget: 0.1% (SLO = 99.9%)
Monthly budget: 43.2 minutes of downtime

Window 1: 14.4x burn over 1h + 5m windows → CRITICAL (page now)
  14.4x means: exhausts monthly budget in 2 hours
  Error rate threshold: 0.001 × 14.4 = 0.0144 (1.44%)
  Both windows must be true: prevents brief spike from paging

Window 2: 6x burn over 6h + 30m windows → CRITICAL (page now)
  6x means: exhausts monthly budget in 5 days
  Error rate threshold: 0.001 × 6 = 0.006 (0.6%)

Window 3: 3x burn over 1d + 2h windows → WARNING (create ticket)
  3x means: exhausts monthly budget in 10 days
  Error rate threshold: 0.001 × 3 = 0.003 (0.3%)

Window 4: 1x burn over 3d + 6h windows → WARNING (informational)
  1x means: exactly burning the budget, will exhaust at month end
  Error rate threshold: 0.001 (0.1%)
```

**Why two windows per alert?** The first window (short) detects current rate. The second window (long) confirms sustained burn — eliminates false positives from transient spikes.

```
Transient spike: 5% error rate for 30 seconds
  5m window: fires!
  1h window: < threshold (30s spike barely moves a 1h average)
  Result: alert doesn't fire — CORRECT, spike was transient

Real incident: 1.5% error rate for 20 minutes
  5m window: fires!
  1h window: also fires (20 min is significant in 1h window)
  Result: alert fires — CORRECT, this is a real problem
```

---

## Recording Rules

Recording rules pre-compute expensive queries and store the result as new metrics. This makes alert evaluation fast.

```yaml
# k8s/slos/app-slos.yaml
- record: slo:order_service:error_rate5m
  expr: |
    sum(rate(order_requests_total{status=~"5.."}[5m])) /
    sum(rate(order_requests_total[5m]))
```

**Why `rate()` instead of just counting?** `rate()` computes per-second rate from a counter, handling counter resets (pod restarts). The `[5m]` window averages the rate over 5 minutes.

**Why `{status=~"5.."}` ?** This regex matches any status code starting with 5 — captures 500, 502, 503, 504, etc. The `=~` operator means regex match in PromQL.

**Why pre-compute at 30s interval?**
Without recording rules, the alert expression:
```promql
sum(rate(order_requests_total{status=~"5.."}[5m])) /
sum(rate(order_requests_total[5m])) > (14.4 * 0.001) and
sum(rate(order_requests_total{status=~"5.."}[1h])) /
sum(rate(order_requests_total[1h])) > (14.4 * 0.001)
```
...runs every 15 seconds against billions of data points. With recording rules:
```promql
slo:order_service:error_rate5m > (14.4 * 0.001) and
slo:order_service:error_rate1h > (14.4 * 0.001)
```
...looks up pre-computed values — dramatically faster.

### All Recording Rules Per Service

```
slo:<service>:error_rate5m       — 5-minute error rate
slo:<service>:error_rate30m      — 30-minute error rate
slo:<service>:error_rate1h       — 1-hour error rate
slo:<service>:error_rate2h       — 2-hour error rate
slo:<service>:error_rate6h       — 6-hour error rate
slo:<service>:error_rate1d       — 1-day error rate
slo:<service>:error_rate3d       — 3-day error rate
slo:<service>:latency_p95_5m     — P95 latency over 5 minutes
slo:<service>:availability_rate1h — availability = 1 - error_rate1h
slo:<service>:error_budget_remaining — % of monthly budget left
```

---

## Alert Rules

### Critical Fast Burn (Page Immediately)

```yaml
- alert: OrderServiceErrorBudgetBurnCriticalFast
  expr: |
    slo:order_service:error_rate5m  > (14.4 * 0.001) and
    slo:order_service:error_rate1h  > (14.4 * 0.001)
  for: 2m        # Must be sustained for 2 minutes (not a 1-second spike)
  labels:
    severity: critical
  annotations:
    summary: "Order service burning error budget at 14.4x rate"
    description: "At this rate the monthly error budget will be exhausted in ~2 hours."
```

**When does this alert fire?**
- Error rate must exceed 1.44% (14.4 × 0.1%)
- Must be true simultaneously in both 5-minute AND 1-hour windows
- Must persist for 2 minutes

---

### Critical Slow Burn (Page)

```yaml
- alert: OrderServiceErrorBudgetBurnCriticalSlow
  expr: |
    slo:order_service:error_rate30m > (6 * 0.001) and
    slo:order_service:error_rate6h  > (6 * 0.001)
  for: 15m       # Sustained for 15 minutes
  labels:
    severity: critical
  annotations:
    description: "Sustained error rate over 30m+6h windows at 6x burn."
```

**Scenario:** Error rate of 0.7% for 2 hours. The 14.4x alert doesn't fire (0.7% < 1.44%). But 0.7% is 7x the budget, so the 6x alert fires after 15 minutes of confirmation.

---

### Warning (Create Ticket)

```yaml
- alert: OrderServiceErrorBudgetBurnWarning
  expr: |
    slo:order_service:error_rate2h > (3 * 0.001) and
    slo:order_service:error_rate1d > (3 * 0.001)
  for: 1h
  labels:
    severity: warning
```

**Scenario:** Error rate of 0.35% sustained for several hours. Not an emergency, but if it continues, the monthly budget will be half-gone. Create a ticket, investigate root cause.

---

### Error Budget Low (Trend Alert)

```yaml
- alert: OrderServiceErrorBudgetLow
  expr: slo:order_service:error_budget_remaining < 0.25
  labels:
    severity: warning
```

**This is a trend alert, not a rate alert.** It fires when less than 25% of the monthly error budget remains — regardless of current error rate. Even if the service is healthy right now, if 75% of the month's budget was consumed in the first 2 weeks, you're on track to fail the SLO.

**Budget remaining formula:**
```promql
1 - (
  sum(increase(order_requests_total{status=~"5.."}[30d])) /
  sum(increase(order_requests_total[30d]))
) / 0.001    # Divide by SLO error rate (0.1%)
```

- `increase()` gives cumulative total over 30 days
- Divide errors by total = actual error rate
- Divide by 0.001 = how many times over budget
- `1 - result` = remaining fraction (1.0 = full budget, 0 = exhausted)

---

### Latency SLO Alert

```yaml
- alert: OrderServiceLatencySLOViolation
  expr: slo:order_service:latency_p95_5m > 0.5    # 500ms
  for: 5m
  labels:
    severity: warning
    slo: latency
```

```promql
# P95 latency recording rule
histogram_quantile(0.95,
  sum(rate(order_request_duration_seconds_bucket[5m])) by (le))
```

`histogram_quantile(0.95, ...)` finds the value X such that 95% of requests complete within X seconds. If this exceeds 0.5s for 5 minutes, the alert fires.

**Note:** inventory-service has P95 < 300ms SLO (it's faster because it doesn't call downstream services).

---

## AlertManager — Alert Routing

Prometheus evaluates rules and fires alerts. AlertManager handles **what to do** with fired alerts.

**UI:** `https://alertmanager.yourdomain.com`

### Routing Configuration

```yaml
# AlertManager routes alerts by label
route:
  receiver: 'default'
  routes:
    - match:
        severity: critical
      receiver: 'pagerduty'     # Page the on-call engineer
    - match:
        severity: warning
      receiver: 'slack'          # Post to Slack channel
    - match:
        alertname: "Watchdog"
      receiver: 'null'           # Suppress the always-firing healthcheck alert

receivers:
  - name: 'slack'
    slack_configs:
      - api_url: '<slack-webhook-from-sm>'
        channel: '#alerts'
        title: '{{ .GroupLabels.alertname }}'
        text: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'
```

**The Watchdog alert** is a special alert that always fires — it's the "dead man's switch" that proves AlertManager itself is working. If you stop receiving Watchdog notifications, AlertManager is broken.

---

## Reading the SLO Dashboard

Open Grafana → Dashboards → **SLO Dashboard**:

### Panel 1: Current Availability
```promql
slo:order_service:availability_rate1h * 100
```
Shows a number like `99.94%`. The target line is at 99.9%.

### Panel 2: Error Budget Remaining
```promql
slo:order_service:error_budget_remaining * 100
```
- 100% = no errors this month (full budget)
- 50% = half of allowed errors consumed
- 0% = SLO violated (budget exhausted)
- Negative = SLO violated (more errors than allowed)

### Panel 3: Burn Rate Gauge
```promql
slo:order_service:error_rate5m / 0.001
```
Shows current burn rate as a multiple of budget:
- 1x = burning exactly at budget rate (will just hit limit by month end)
- 6x = orange zone (slow burn alert)
- 14.4x = red zone (fast burn, page now)

### Panel 4: Error Rate Timeline (30 days)
Shows when error rates spiked, for how long, and how much budget each spike consumed.

---

## Hands-on Labs

### Lab 1: Watch the Burn Rate in Real Time

```bash
# Step 1: Generate load with errors
kubectl port-forward svc/order-service 8000:8000 -n apps &

# Step 2: In Prometheus, query the error rate
# https://prometheus.yourdomain.com
# Query: slo:order_service:error_rate5m * 100
# Expected: ~2% (order-service has ~2% simulated error rate)

# Step 3: Calculate the burn rate
# 2% / 0.1% = 20x burn rate
# At 20x, monthly budget exhausts in: (30 days × 24h × 60min) / 20 = 2.16 hours
# The 14.4x critical alert should fire within 2 minutes

# Step 4: Check Alertmanager
# https://alertmanager.yourdomain.com
# OrderServiceErrorBudgetBurnCriticalFast should appear
```

### Lab 2: Simulate SLO Violation

```bash
# Scale to 0 (100% error rate = 1000x burn)
kubectl scale deployment order-service -n apps --replicas=0

# The 5-minute window will show 100% error rate almost immediately
# Burn rate: 100% / 0.1% = 1000x
# Budget exhaustion: minutes

# Watch in Prometheus:
# slo:order_service:error_budget_remaining → approaches 0

# Restore:
kubectl scale deployment order-service -n apps --replicas=2
```

---

## Interview Questions — SLOs & Alerting

**Q1: What's the difference between an SLI, SLO, and SLA?**
> *Answer:* "An SLI is the measurement — the actual number like '99.94% requests returned 2xx'. An SLO is the internal target you commit to — '99.9% availability over 30 days'. An SLA is the contractual commitment with a customer, typically looser than the SLO — '99.5% availability, with penalties for breach'. You always want your SLO stricter than your SLA so that you can violate your SLO internally (triggering an incident response) while still meeting your SLA externally. An SLO breach is 'we need to fix this'. An SLA breach is 'we owe the customer money'."

**Q2: Why is multi-window burn-rate alerting better than simple error rate thresholds?**
> *Answer:* "Simple threshold alerting (`alert if error_rate > 1%`) has two failure modes: false positives (a 2-second spike at 5% fires an alert at 3am for nothing) and missed incidents (a sustained 0.2% error rate never fires but consumes the entire monthly budget in 15 days). Multi-window burn-rate alerts solve both: dual windows prevent spikes from firing (5m fires but 1h doesn't → no alert), and budget-consumption math catches slow burns (6x burn for 5 days exhausts budget by month 15 → 3x warning fires). The alerts tell you: 'at this rate, you'll exhaust your error budget in X hours' — that's actionable information, not just a threshold violation."

**Q3: If the error budget is at 80% consumed with 2 weeks left, what should you do?**
> *Answer:* "Stop risky deployments. The error budget is a conversation tool between product and reliability: if the budget is nearly gone, deploying a big feature creates risk of budget exhaustion and SLO violation. Engineering should freeze non-critical deployments and focus on reliability improvements: add retries, improve health checks, fix known flaky components. Alternatively, hold a reliability sprint — identify the top 3 causes of errors from Grafana, fix them, and use the remaining 2 weeks of stability to recover budget. This is the SRE model: error budgets make reliability discussions quantitative instead of opinion-based."

**Q4: How does `histogram_quantile` work in Prometheus?**
> *Answer:* "Prometheus histograms store request counts in pre-defined buckets — 'how many requests completed in under 0.1s', 'under 0.5s', etc. `histogram_quantile(0.95, ...)` uses linear interpolation between buckets to find the value X where 95% of observations fall below X. For example, if the 0.5s bucket has 950/1000 requests, P95 latency ≈ 0.5s. The accuracy depends on bucket granularity — our buckets go from 5ms to 2.5s, which gives good precision in the 100-500ms range where our SLO targets are. Without histograms, you can't calculate percentiles — you can only average, which hides the long tail."

**Q5: What is the Watchdog alert and why is it important?**
> *Answer:* "Watchdog is a PrometheusRule that always fires — its expression is `vector(1)`, which is always true. It tests the full alerting pipeline: Prometheus evaluates rules → Alertmanager receives the alert → Alertmanager routes it to Slack/PagerDuty → notification arrives. If Watchdog notifications stop coming, it means something in that pipeline is broken — Prometheus stopped scraping, Alertmanager crashed, or the notification channel is down. Without Watchdog, you might think 'no alerts = everything is fine' when actually your alerting pipeline is silently broken. It's a 'dead man's switch' for your observability stack."

---

## What's Next?

→ **[11-aiops.md](11-aiops.md)** — How the AI agent responds to SLO burn-rate alerts automatically
→ **[14-chaos-load-testing.md](14-chaos-load-testing.md)** — Trigger burn-rate alerts intentionally with Locust and chaos endpoints
→ **[13-troubleshooting.md](13-troubleshooting.md)** — AlertManager not routing, Prometheus recording rules not appearing
