# AIOps Demo — Production Observability Microservices

A production-grade set of instrumented microservices designed for **AIOps / observability platform testing** on Amazon EKS.
Every service emits **metrics, traces, structured logs, and chaos signals** so your monitoring stack has real data to alert on from day one.

---

## 📦 What's Included

```
aiops-demo/
├── services/
│   ├── order-service/          FastAPI — orders, CPU/memory stress, downstream calls
│   ├── payment-service/        FastAPI — payments, circuit breaker, fraud detection, retry storm
│   ├── inventory-service/      FastAPI — inventory, disk I/O stress, cache simulation
│   └── load-generator/         Locust — drives realistic + chaos traffic automatically
└── k8s/
    ├── deployments/            K8s Deployments (one per service)
    ├── services/               ClusterIP + Headless Services + Namespace + ServiceAccount
    ├── hpa/                    HorizontalPodAutoscalers (CPU + memory based)
    └── configmaps/             OTEL Collector pipeline config + env config
```

---

## 🏗️ Architecture

```
                    ┌─────────────────────────────────────────┐
                    │           aiops-demo namespace           │
                    │                                          │
  Internet ──► Kong/Traefik  ──►  order-service  :8000        │
  (Helm install)              ──►  payment-service :8002       │
                              ──►  inventory-service :8001     │
                                                               │
                    │  load-generator (Locust) drives traffic  │
                    └─────────────────────────────────────────┘
                                        │
                         OpenTelemetry Collector (Helm)
                         ┌──────────────┼──────────────┐
                     Metrics         Traces           Logs
                         │              │              │
                    Prometheus        Tempo           Loki
                         └──────────────┼──────────────┘
                                    Grafana
                                  (single pane)
```

---

## 🔭 Observability Coverage

| Signal | What's generated | Where it goes |
|---|---|---|
| **HTTP metrics** | Request count, latency histograms, status codes | Prometheus `/metrics` |
| **CPU metrics** | CPU stress endpoint spikes load to 100% | Prometheus + HPA |
| **Memory metrics** | Leak endpoint grows heap without freeing | Prometheus + OOMKilled |
| **Disk I/O** | Write/read stress with latency histograms | Prometheus |
| **Distributed traces** | OTEL spans across all 3 services | Tempo / Jaeger |
| **Structured logs** | JSON logs with trace IDs, event types, severity | Loki / ELK |
| **Error rates** | Configurable error injection (0-100%) | Prometheus |
| **Circuit breaker** | Opens/closes with state gauge | Prometheus |
| **Retry storms** | Rapid retry counter increments | Prometheus |
| **Latency / SLO breach** | Configurable slow endpoints (100ms–30s) | Prometheus + Grafana SLO |
| **Downstream cascade** | Forced timeout to dependent services | Traces + error metrics |
| **Low stock alerts** | Inventory drain triggers threshold alert | Prometheus |
| **Fraud signals** | High-value payment fraud check counter | Prometheus |
| **K8s liveness/readiness** | All services have proper probes | K8s Events |
| **Auto-scaling events** | HPA fires when CPU/mem > 60/70% | K8s HPA metrics |

---

## 🚀 Quick Start

### 1. Prerequisites

```bash
# Required
kubectl  >= 1.28
helm     >= 3.12
eksctl   >= 0.175  (for EKS)

# Your ECR / container registry
AWS_ACCOUNT=123456789012
AWS_REGION=ap-south-1
ECR_REGISTRY=$AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com
```

### 2. Build & Push Images

```bash
# Login to ECR
aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS --password-stdin $ECR_REGISTRY

# Build all services
for svc in order-service payment-service inventory-service load-generator; do
  docker build -t $ECR_REGISTRY/aiops-$svc:latest services/$svc/
  docker push $ECR_REGISTRY/aiops-$svc:latest
done
```

### 3. Update Image References

Edit each deployment file and replace `your-registry/` with your ECR URI:

```bash
# Quick sed replace
find k8s/deployments/ -name "*.yaml" -exec \
  sed -i "s|your-registry|$ECR_REGISTRY/aiops|g" {} \;
```

### 4. Install Observability Stack (Helm — infra layer)

```bash
# Add Helm repos
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana              https://grafana.github.io/helm-charts
helm repo add open-telemetry       https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

# Create monitoring namespace
kubectl create namespace monitoring

# kube-prometheus-stack (Prometheus + Alertmanager + Grafana)
helm install kube-prom prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set prometheus.prometheusSpec.enableRemoteWriteReceiver=true \
  --set grafana.adminPassword=admin

# Loki stack (Loki + Promtail)
helm install loki grafana/loki-stack \
  --namespace monitoring \
  --set grafana.enabled=false \
  --set promtail.enabled=true

# Tempo (distributed tracing backend)
helm install tempo grafana/tempo \
  --namespace monitoring

# OpenTelemetry Collector
helm install otel-collector open-telemetry/opentelemetry-collector \
  --namespace monitoring \
  --set mode=deployment

# API Gateway — Kong (replaces deprecated nginx-ingress)
helm repo add kong https://charts.konghq.com
helm install kong kong/kong \
  --namespace kong \
  --create-namespace \
  --set ingressController.installCRDs=false \
  --set proxy.type=LoadBalancer
```

### 5. Deploy the OTEL Collector Config

```bash
kubectl apply -f k8s/configmaps/otel-config.yaml
```

### 6. Deploy the Apps

```bash
# Create namespace + services first
kubectl apply -f k8s/services/all-services.yaml

# Deploy all services
kubectl apply -f k8s/deployments/

# Apply HPAs
kubectl apply -f k8s/hpa/all-hpa.yaml

# Verify everything is running
kubectl get pods -n aiops-demo
kubectl get hpa  -n aiops-demo
kubectl get svc  -n aiops-demo
```

---

## 📡 Chaos Endpoint Reference

### order-service (port 8000)

| Endpoint | Method | Description | AIOps Signal |
|---|---|---|---|
| `GET /stress/cpu?duration=15` | GET | Burns CPU for N seconds | CPU spike alert |
| `GET /stress/memory?mb=100` | GET | Leaks N MB (not freed) | Memory alert / OOMKilled |
| `GET /stress/memory/reset` | GET | Clears leaked memory | — |
| `GET /slow?delay=5000` | GET | Sleeps N ms | Latency / SLO breach alert |
| `GET /error?rate=50` | GET | 500 error at N% probability | Error rate alert |
| `GET /downstream/timeout` | GET | Forces downstream timeout | Cascade failure alert |
| `GET /downstream/call` | GET | Normal distributed call | Multi-service trace |
| `POST /orders` | POST | Creates an order | Normal business metric |

### payment-service (port 8002)

| Endpoint | Method | Description | AIOps Signal |
|---|---|---|---|
| `POST /payments` | POST | Processes payment (3% failure rate built-in) | Payment SLI |
| `POST /chaos/circuit-open?duration=60` | POST | Opens circuit breaker | Circuit breaker alert |
| `POST /chaos/circuit-close` | POST | Closes circuit breaker | — |
| `GET /slow?delay=5000` | GET | Slow gateway simulation | P99 latency alert |
| `GET /error?rate=75` | GET | Payment error injection | Error budget burn |
| `GET /chaos/retry-storm?count=50` | GET | Simulates retry storm | Retry rate alert |

### inventory-service (port 8001)

| Endpoint | Method | Description | AIOps Signal |
|---|---|---|---|
| `GET /stress/disk/write?files=20&size_kb=1024` | GET | Writes stress files | Disk I/O saturation |
| `GET /stress/disk/read?files=20` | GET | Reads stress files | Disk read latency |
| `DELETE /stress/disk/cleanup` | DELETE | Cleans temp files | — |
| `GET /chaos/stock-drain` | GET | Sets all stock to 0 | Low-stock threshold alert |
| `GET /chaos/stock-restore` | GET | Restores stock levels | — |
| `GET /slow?delay=3000` | GET | Slow DB query simulation | DB latency alert |

---

## 📊 Grafana Dashboards to Import

After deploying, add these data sources in Grafana:

| Data Source | URL |
|---|---|
| Prometheus | `http://kube-prom-prometheus.monitoring.svc.cluster.local:9090` |
| Loki        | `http://loki.monitoring.svc.cluster.local:3100` |
| Tempo       | `http://tempo.monitoring.svc.cluster.local:3100` |

Recommended dashboard IDs to import from grafana.com:

| Dashboard | ID |
|---|---|
| Kubernetes / Compute Resources / Namespace | 17781 |
| FastAPI Observability | 16110 |
| Node Exporter Full | 1860 |
| Loki Logs Panel | 13639 |

---

## ⚡ Key Prometheus Metrics Per Service

### order-service
```promql
# Request rate
rate(order_requests_total[5m])

# P99 latency
histogram_quantile(0.99, rate(order_request_duration_seconds_bucket[5m]))

# Error rate
rate(order_errors_total[5m])

# Active orders
orders_active_total

# Memory leak
order_memory_leak_bytes

# CPU stress active
order_cpu_stress_active
```

### payment-service
```promql
# Payment success rate
rate(payments_processed_total{result="success"}[5m])

# Circuit breaker state
payment_circuit_breaker_open

# Retry rate
rate(payment_retries_total[5m])

# Gateway P99 latency
histogram_quantile(0.99, rate(payment_gateway_latency_secs_bucket[5m]))

# Fraud detections
rate(payment_fraud_detected_total[5m])
```

### inventory-service
```promql
# Disk write latency P95
histogram_quantile(0.95, rate(inventory_disk_write_secs_bucket[5m]))

# Low stock items
inventory_low_stock_items

# Cache hit rate
rate(inventory_cache_ops_total{result="hit"}[5m])
  / rate(inventory_cache_ops_total[5m])
```

---

## 🔔 Recommended Alertmanager Rules

```yaml
# High error rate
- alert: HighErrorRate
  expr: rate(order_errors_total[5m]) > 0.05
  for: 2m
  labels:
    severity: warning

# Circuit breaker open
- alert: PaymentCircuitBreakerOpen
  expr: payment_circuit_breaker_open == 1
  for: 1m
  labels:
    severity: critical

# High P99 latency
- alert: HighP99Latency
  expr: histogram_quantile(0.99, rate(order_request_duration_seconds_bucket[5m])) > 2
  for: 5m
  labels:
    severity: warning

# Memory leak
- alert: MemoryLeaking
  expr: order_memory_leak_bytes > 100000000   # 100MB
  for: 2m
  labels:
    severity: warning

# Low stock
- alert: LowInventory
  expr: inventory_low_stock_items > 20
  for: 5m
  labels:
    severity: info
```

---

## 🧪 Load Testing Scenarios

```bash
# Port-forward Locust web UI
kubectl port-forward -n aiops-demo svc/load-generator 8089:8089
# Open http://localhost:8089 — control virtual users from UI

# Headless — 50 users, ramp 5/sec for 10 minutes
kubectl exec -n aiops-demo deploy/load-generator -- \
  locust --headless -u 50 -r 5 --run-time 10m

# Pure chaos run — only fire chaos endpoints
kubectl exec -n aiops-demo deploy/load-generator -- \
  locust --headless -u 5 -r 1 --run-time 5m \
  --tags chaos
```

---

## 🔐 Security Notes

- All pods run as **non-root** (UID 1000)
- Resources have `requests` and `limits` set to prevent noisy-neighbour issues
- Inventory disk stress is capped at **2Gi** via `emptyDir.sizeLimit`
- Memory leak endpoint is capped at **500MB** per call via query param validation
- CPU stress is capped at **60 seconds** per call

---

## 🗺️ What You Install Separately (Helm / Infra)

This repo covers **apps only**. You handle:

| Component | Helm Chart |
|---|---|
| API Gateway | `kong/kong` |
| Metrics | `prometheus-community/kube-prometheus-stack` |
| Logs | `grafana/loki-stack` |
| Traces | `grafana/tempo` |
| Collection | `open-telemetry/opentelemetry-collector` |
| Cluster Autoscaler | `autoscaler/cluster-autoscaler` |

---

## 📝 License

MIT — use freely for internal AIOps platform development and testing.
