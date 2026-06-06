# AIOps Guide

> **What you'll learn:** What the four AIOps workloads do, how the anomaly detection → alert correlation → AI agent pipeline works, how AWS Bedrock Claude is invoked for auto-remediation, and the business case for AI-driven operations.

---

## Why AIOps?

A 2024 enterprise Kubernetes cluster generates ~50,000 metrics, ~1 million log lines per hour, and dozens of alerts daily. A human SRE physically cannot read all of this. AIOps applies:
- **ML-based anomaly detection**: Find unusual patterns without manually setting every threshold
- **Alert correlation**: Group 20 related alerts into 1 root cause
- **AI-powered root cause analysis**: Explain what's wrong and suggest a fix
- **Auto-remediation**: Optionally execute the fix automatically

This project implements a complete AIOps pipeline using four microservices, AWS SQS for decoupling, and AWS Bedrock (Claude Sonnet) for AI reasoning.

---

## Architecture Overview

```
Prometheus metrics
      │
      ▼
Anomaly Detector (ML service)
  ├── Trains Isolation Forest model on startup
  ├── Continuously polls Prometheus for metrics
  ├── Detects anomalies (error rate spikes, latency outliers)
  └── Sends anomaly event → SQS Queue: intelliops-anomalies
                                    │
                    ┌───────────────┘
                    ▼
            Alert Correlator
              ├── Polls Alertmanager every 5 minutes
              ├── Groups related alerts by service/time window
              └── Sends correlated alert group → SQS Queue
                                    │
                    ┌───────────────┘
                    ▼
            AI Agent (Claude Sonnet)
              ├── Polls SQS queue every 30 seconds
              ├── For each message: queries Prometheus + Loki for context
              ├── Calls AWS Bedrock (Claude Sonnet) with context
              ├── Claude analyzes and generates remediation steps
              └── Executes approved actions:
                    ├── kubectl scale deployment (increase replicas)
                    ├── kubectl rollout restart (fix stuck pods)
                    ├── ArgoCD rollback (revert bad deployment)
                    └── Slack notification with full analysis

Forecaster (independent)
  ├── Queries Prometheus for historical metric data
  └── Generates capacity forecasts (will node run out of memory in 2 days?)
```

---

## Workload 1: Anomaly Detector

**Namespace:** `aiops-demo`
**Image:** `intelliops-dev/anomaly-detector`

### What It Does

Uses a machine learning algorithm (Isolation Forest) to detect anomalies in Prometheus metrics without requiring manual threshold configuration.

**The Isolation Forest principle:**
> "Normal observations are hard to isolate — they require many splits in a decision tree. Anomalous observations are easy to isolate — they're isolated quickly because they're far from the cluster."

In simpler terms: the algorithm learns what "normal" looks like, then flags anything that doesn't fit.

### How It Starts (Init Container)

```yaml
initContainers:
  - name: train-model
    command: ["python", "train.py"]
    env:
      - PROMETHEUS_URL: http://prometheus.monitoring.svc:9090
      - MODEL_PATH: /models/anomaly_model.pkl
    volumeMounts:
      - name: model-storage
        mountPath: /models
```

1. Queries Prometheus for the last 24 hours of metrics:
   - `order_requests_total`, `order_request_duration_seconds_*`
   - `payment_requests_total`, `payment_request_duration_secs_*`
   - `inventory_requests_total`
2. Trains an Isolation Forest model on this data
3. Saves the model to `/models/anomaly_model.pkl` (emptyDir shared volume)
4. Init container exits → main container starts

**Why init container?** The main container (inference) depends on the trained model. Using an init container guarantees the model exists before inference starts, without complex startup logic in the main container.

### Detection Loop

Every 60 seconds (configurable via `POLL_INTERVAL_SECONDS`), the main container:
1. Queries Prometheus for current metric values
2. Runs the data through the trained model
3. If anomaly score > threshold: publishes to SQS

**SQS message format:**
```json
{
  "source": "anomaly-detector",
  "timestamp": "2024-01-15T10:30:00Z",
  "service": "order-service",
  "metric": "error_rate",
  "current_value": 0.045,
  "expected_range": [0.01, 0.025],
  "anomaly_score": 0.87,
  "severity": "high"
}
```

### IRSA for SQS Access

```yaml
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: <intelliops-dev-anomaly-detector-irsa>
```

The IRSA role has `sqs:SendMessage` on the `intelliops-anomalies` queue. No AWS credentials in the pod — the OIDC token exchange provides temporary credentials automatically.

---

## Workload 2: Alert Correlator

**What It Does:** Groups related alerts from AlertManager into a single correlated event, preventing alert storms from creating N independent investigations.

**The problem it solves:**
```
Without correlation:
  Alert 1: OrderServiceErrorBudgetBurnCriticalFast
  Alert 2: PaymentServiceErrorBudgetBurnCriticalFast
  Alert 3: InventoryServiceErrorBudgetBurnCriticalFast
  Alert 4: OrderServiceLatencySLOViolation
  → 4 separate Slack messages, 4 separate SQS events, 4 AI analyses
  → SRE sees: 4 pages, doesn't know they're all caused by one thing

With correlation (CORRELATION_WINDOW_SECONDS=300):
  All 4 alerts fired within 5 minutes of each other
  → Grouped as: "Multi-service cascade at 10:30 UTC"
  → 1 Slack message, 1 SQS event, 1 AI analysis
  → Root cause: network partition between Kong and services
```

**Correlation logic:**
- Groups alerts that fire within the same `CORRELATION_WINDOW_SECONDS` (300s = 5 min)
- Computes likely root service (the one with the earliest alert)
- Adds severity score based on number and severity of alerts
- Publishes single correlated event to SQS

---

## Workload 3: AI Agent (Claude Sonnet)

**Namespace:** `aiops-demo`
**Image:** `intelliops-dev/ai-agent`
**Model:** `anthropic.claude-sonnet-4-5` via AWS Bedrock

### IRSA Permissions

```yaml
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: <intelliops-dev-ai-agent-irsa>
```

IAM permissions on the IRSA role:
- `bedrock:InvokeModel` — call Claude via Bedrock API
- `sqs:ReceiveMessage`, `sqs:DeleteMessage` — consume from anomaly queue
- K8s RBAC (via Role/RoleBinding in apps namespace):
  - `pods: get, list, delete`
  - `deployments: get, list, patch`
  - `horizontalpodautoscalers: get, list`
  - `pods/log: get`
  - `events: get, list`

### The AI Agent Loop

Every 30 seconds (`POLL_INTERVAL_SECONDS`):

```
1. Poll SQS: receive anomaly/correlation messages
   ┌─────────────────────────────────────────┐
   │ SQS message: "order-service anomaly"    │
   └─────────────────────────────────────────┘
           │
           ▼
2. Gather context (before calling Claude):
   ├── Prometheus: current error rate, latency P95 (last 30m)
   ├── Loki: last 100 error log lines from affected service
   ├── Kubernetes: pod status, recent events, restart count
   └── ArgoCD: last deployment time and image tag
           │
           ▼
3. Build prompt for Claude:
   "You are an SRE. An anomaly was detected in order-service.
    Context: error rate is 4.5% (normally ~2%), latency P95 is 850ms,
    3 pods are running, last deployment was 15 minutes ago.
    Recent logs: [last 100 error lines]
    Recent K8s events: [pod events]
    What is the likely root cause and what remediation steps do you recommend?"
           │
           ▼
4. Call AWS Bedrock (Claude Sonnet):
   bedrock_client.invoke_model(
     modelId="anthropic.claude-sonnet-4-5",
     body=json.dumps({
       "anthropic_version": "bedrock-2023-05-31",
       "messages": [{"role": "user", "content": prompt}],
       "max_tokens": 1024
     })
   )
           │
           ▼
5. Parse Claude's response:
   {
     "root_cause": "Recent deployment introduced memory leak — OOMKills increasing",
     "confidence": "high",
     "remediation": [
       {"action": "rollback", "target": "order-service", "description": "Rollback to previous image"},
       {"action": "scale", "target": "order-service", "replicas": 4, "description": "Temporary scale-up"}
     ],
     "notify": "OrderService anomaly detected post-deployment. Recommending rollback."
   }
           │
           ▼
6. Execute approved actions:
   ├── ArgoCD rollback: argocd app rollback microservices
   ├── kubectl scale: patch HPA or Deployment
   └── Slack notification with full analysis
           │
           ▼
7. Delete SQS message (processing complete)
```

### What Claude Can and Cannot Do

**Can do (RBAC-controlled):**
- Scale deployments up or down
- Restart pods (`kubectl rollout restart`)
- Trigger ArgoCD rollback
- Read pod logs for diagnosis
- Read Prometheus metrics for context
- Send Slack notifications

**Cannot do (not in IRSA/RBAC):**
- Delete namespaces
- Modify cluster-level resources
- Change security policies
- Access Secrets (no `secrets: get` in RBAC)
- Access other namespaces (Role is scoped to `apps`)

**Why limit actions?** Claude might be wrong. Limiting the blast radius of auto-remediation means the worst case is "wrongly scaled to 4 replicas" not "deleted the production namespace."

---

## Workload 4: Forecaster

**What It Does:** Queries Prometheus for historical metric trends and generates capacity forecasts.

**Use cases:**
- "At current request growth rate, CPU will be the bottleneck in 8 days"
- "At current log ingestion rate, the Loki disk will fill in 4 days"
- "If the current memory leak in order-service continues, pods will OOMKill in 6 hours"

**Algorithm:** Linear regression on metric time series. For each key metric, the forecaster fits a trend line and projects forward 7 days.

**Output:** Published to Prometheus Pushgateway as metrics:
```
forecast:order_service:cpu_exhaustion_hours 192    # 8 days
forecast:loki:disk_exhaustion_hours 96              # 4 days
```

These appear in the Grafana Cost Dashboard as forecast warnings.

---

## SQS Dead-Letter Queue

```
SQS Queue: intelliops-anomalies
  Message retention: 1 day
  Visibility timeout: 30 seconds

Dead-Letter Queue: intelliops-anomalies-dlq
  Triggered after: 3 failed processing attempts
```

**Why a DLQ?** If the AI agent crashes while processing a message, the message becomes visible again after 30 seconds (visibility timeout). After 3 failures, it goes to the DLQ for manual investigation. Without a DLQ, a poison message could loop forever, blocking the queue.

**Check the DLQ:**
- AWS Console → SQS → `intelliops-anomalies-dlq`
- If messages accumulate: the AI agent is consistently failing on certain message types

---

## AWS Bedrock — Why Claude?

AWS Bedrock is Amazon's managed AI service. We chose Claude Sonnet because:

1. **Native AWS integration**: No external API calls, credentials handled by IAM, traffic stays in-region
2. **No hardcoded API keys**: IRSA + Bedrock permissions — no `ANTHROPIC_API_KEY` anywhere
3. **Reasoning capability**: Claude is good at analyzing structured data (Prometheus metrics, K8s events) and generating structured JSON outputs (remediation plans)
4. **Context window**: 200K token context window — can include extensive log data in the prompt
5. **Instruction following**: Claude follows structured output formats reliably, important for parsing remediation plans

**The `bedrock:InvokeModel` IAM permission is scoped to us-east-1 only** — the IRSA policy includes:
```json
"Resource": "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-5"
```

---

## Observability of AIOps Workloads

All four AIOps workloads expose Prometheus metrics via annotation:
```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8080"
  prometheus.io/path: "/metrics"
```

**Metrics exposed by anomaly-detector:**
```
anomaly_detector_anomalies_detected_total{service="order-service"} 3
anomaly_detector_model_accuracy 0.94
anomaly_detector_prometheus_query_errors_total 0
```

**Metrics exposed by ai-agent:**
```
ai_agent_messages_processed_total 47
ai_agent_bedrock_invocations_total 47
ai_agent_remediations_executed_total{action="scale"} 12
ai_agent_remediations_executed_total{action="rollback"} 2
ai_agent_bedrock_latency_seconds_bucket{le="5"} 41
```

These appear in the Grafana **Services Overview** dashboard and in the AIOps section of the compliance dashboard.

---

## Hands-on Lab: Trigger AIOps Pipeline

```bash
# Step 1: Simulate an anomaly by scaling order-service to 0
kubectl scale deployment order-service -n apps --replicas=0

# Step 2: Wait 60-120 seconds for anomaly-detector to notice

# Step 3: Check SQS queue for the anomaly message
aws sqs get-queue-attributes \
  --queue-url $(aws sqs get-queue-url --queue-name intelliops-anomalies --query QueueUrl --output text) \
  --attribute-names ApproximateNumberOfMessages
# Shows: "ApproximateNumberOfMessages": "1"

# Step 4: Watch AI agent logs
kubectl logs -n aiops-demo deployment/ai-agent -f
# You'll see: "Received anomaly message", "Querying Prometheus context",
#             "Calling Bedrock", "Executing remediation"

# Step 5: Check Slack for the AI analysis notification

# Step 6: Restore manually (or let the AI agent do it)
kubectl scale deployment order-service -n apps --replicas=2
```

---

## Interview Questions — AIOps

**Q1: Why use an ML anomaly detector instead of just setting metric thresholds?**
> *Answer:* "Manual thresholds require someone who knows the system to decide 'error rate > 5% is bad'. But what if normal error rate varies by time of day — it's 1% at night but 3% during peak? A static threshold either misses daytime anomalies or pages at night for normal behavior. Isolation Forest learns the pattern of normal — it knows that 3% at 2pm on a weekday is normal but 3% at 3am is anomalous. This is especially valuable for new services where you don't yet know what 'normal' looks like."

**Q2: How does the AI agent avoid making the situation worse during remediation?**
> *Answer:* "Three constraints: First, RBAC limits what the agent can do — it can scale deployments and restart pods in the apps namespace, but can't touch security policies, secrets, or cluster-scoped resources. Second, the remediation actions Claude suggests are structured JSON with specific types (`scale`, `rollback`, `restart`) — the agent only executes recognized action types, ignoring any free-form instructions. Third, the agent always sends a Slack notification before and after executing actions — a human can see what happened and intervene. In the future, a 'confirmation mode' could require human approval before executing, keeping humans in the loop for high-risk actions."

**Q3: Why use SQS between the anomaly detector and AI agent instead of direct calling?**
> *Answer:* "Decoupling via SQS provides several benefits. First, the anomaly detector can send messages whether or not the AI agent is running — messages persist in SQS for 1 day. If the AI agent is being upgraded, no anomaly events are lost. Second, the AI agent controls its own processing rate (30s poll) regardless of how fast anomalies arrive — no back-pressure problem. Third, the DLQ captures failed messages for diagnosis — if Claude starts returning unexpected formats, the DLQ fills up as an early warning. Direct calling would require synchronous HTTP, retry logic, and circuit breakers in every component."

**Q4: How does Claude know what to do without seeing your codebase?**
> *Answer:* "The prompt is the key. We don't send Claude raw data — we send structured context: current metric values, error logs, pod events, recent deployment info, and explicit questions like 'does the timing of this anomaly correlate with the deployment 15 minutes ago?' Claude uses this context plus its training on Kubernetes, Prometheus, and SRE patterns to reason about what's wrong. The output is structured JSON with specific action types — the agent code maps these to kubectl or ArgoCD commands. Claude doesn't need to know our specific codebase; it understands Kubernetes semantics and common failure patterns from training."

**Q5: What's the business case for AIOps at an enterprise?**
> *Answer:* "At a bank or fintech with hundreds of services, manual incident response is too slow. The SLO dashboard shows a 2-hour burn rate, AlertManager pages the on-call SRE, they wake up at 3am, take 30 minutes to understand the context, another 30 minutes to diagnose, then execute a fix. Total MTTR: 90 minutes — that's most of the monthly error budget consumed in one incident. With AIOps: anomaly detected in 60 seconds, AI generates root cause analysis in 5 seconds, auto-remediation executes in 10 seconds, Slack notification sent. MTTR drops from 90 minutes to 3 minutes. At $10,000/minute SLA cost, that's potentially $870,000 saved per incident."

---

## What's Next?

→ **[12-cost-aws-guide.md](12-cost-aws-guide.md)** — AWS Console guide including Bedrock, SQS, and CloudWatch for AIOps monitoring
→ **[14-chaos-load-testing.md](14-chaos-load-testing.md)** — Trigger anomalies with Locust and watch the AI agent respond in Slack
→ **[13-troubleshooting.md](13-troubleshooting.md)** — AIOps pod CrashLoopBackOff, SQS permission errors, Bedrock access issues
