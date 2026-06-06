#!/usr/bin/env bash
# demo-chaos.sh — end-to-end AIOps chaos demo
#
# Runs a complete demo cycle:
#   1. Verify all services are healthy (pre-chaos baseline)
#   2. Trigger LitmusChaos experiment on target service
#   3. Monitor Prometheus metrics for anomaly detection
#   4. Verify anomaly-detector published to SQS
#   5. Verify ai-agent picked up and sent Slack notification
#   6. Show recovery and Grafana dashboard URL
#
# Usage:
#   ./scripts/demo-chaos.sh [order|payment|inventory|network]
#
# Defaults to order-service pod-delete if no argument given.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHAOS_DIR="${REPO_ROOT}/k8s/chaos"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
ACCOUNT="${AWS_ACCOUNT_ID:-007066145518}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
step()    { echo -e "\n${BOLD}══ $* ══${NC}"; }

SCENARIO="${1:-order}"

case "${SCENARIO}" in
  order)    CHAOS_FILE="pod-delete-order.yaml";          TARGET="order-service";    NAMESPACE="apps"; PORT=8000 ;;
  payment)  CHAOS_FILE="pod-cpu-hog-payment.yaml";       TARGET="payment-service";  NAMESPACE="apps"; PORT=8002 ;;
  inventory) CHAOS_FILE="pod-memory-hog-inventory.yaml"; TARGET="inventory-service"; NAMESPACE="apps"; PORT=8001 ;;
  network)  CHAOS_FILE="network-loss-apps.yaml";         TARGET="order-service";    NAMESPACE="apps"; PORT=8000 ;;
  *) error "Unknown scenario '${SCENARIO}'. Use: order | payment | inventory | network"; exit 1 ;;
esac

# ── 0. Pre-checks ─────────────────────────────────────────────────────────────
step "0/6  Pre-flight checks"

command -v kubectl &>/dev/null || { error "kubectl not found"; exit 1; }
command -v aws     &>/dev/null || { error "aws CLI not found"; exit 1; }

kubectl get namespace apps &>/dev/null       || { error "Namespace 'apps' not found — is the stack deployed?"; exit 1; }
kubectl get namespace aiops-demo &>/dev/null || { error "Namespace 'aiops-demo' not found — run install-stack.sh first"; exit 1; }
kubectl get namespace litmus &>/dev/null     || { error "Namespace 'litmus' not found — LitmusChaos not installed"; exit 1; }

success "Namespaces verified"

# ── 1. Baseline health check ──────────────────────────────────────────────────
step "1/6  Baseline health check"

for svc in order-service payment-service inventory-service; do
  READY=$(kubectl get deployment "${svc}" -n apps -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  DESIRED=$(kubectl get deployment "${svc}" -n apps -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
  if [ "${READY}" = "${DESIRED}" ] && [ "${READY}" != "0" ]; then
    success "${svc}: ${READY}/${DESIRED} replicas ready"
  else
    warn "${svc}: ${READY}/${DESIRED} replicas ready — continuing anyway"
  fi
done

AD_READY=$(kubectl get deployment anomaly-detector -n aiops-demo -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
AI_READY=$(kubectl get deployment ai-agent -n aiops-demo -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
[ "${AD_READY}" -ge 1 ] && success "anomaly-detector: running" || warn "anomaly-detector: not ready (${AD_READY} replicas)"
[ "${AI_READY}" -ge 1 ] && success "ai-agent: running"         || warn "ai-agent: not ready (${AI_READY} replicas)"

# ── 2. Trigger chaos ──────────────────────────────────────────────────────────
step "2/6  Triggering chaos: ${SCENARIO} (${CHAOS_FILE})"

info "Applying chaos experiment: ${CHAOS_FILE}"
kubectl apply -f "${CHAOS_DIR}/${CHAOS_FILE}"

ENGINE_NAME=$(grep "^  name:" "${CHAOS_DIR}/${CHAOS_FILE}" | head -1 | awk '{print $2}')
info "ChaosEngine: ${ENGINE_NAME} in namespace ${NAMESPACE}"

# Also trigger via service endpoint for faster anomaly signal
SVC_IP=$(kubectl get svc "${TARGET}" -n "${NAMESPACE}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
if [ -n "${SVC_IP}" ]; then
  case "${SCENARIO}" in
    payment)
      info "Enabling CPU chaos on ${TARGET} via /chaos/cpu?duration=60"
      kubectl exec -n apps deploy/payment-service -- \
        curl -s -X POST "http://localhost:${PORT}/chaos/cpu?duration=60" &>/dev/null || true ;;
    inventory)
      info "Enabling memory chaos on ${TARGET} via /chaos/memory"
      kubectl exec -n apps deploy/inventory-service -- \
        curl -s -X POST "http://localhost:${PORT}/chaos/disk-stress?file_count=50&file_size_mb=10" &>/dev/null || true ;;
    order|network)
      info "Enabling slow-response chaos on ${TARGET} via /chaos/slow?delay=500"
      kubectl exec -n apps deploy/order-service -- \
        curl -s -X POST "http://localhost:${PORT}/chaos/slow?delay=500" &>/dev/null || true ;;
  esac
  success "Service-level chaos enabled"
fi

success "Chaos triggered — running for 60 seconds"

# ── 3. Monitor metrics during chaos ──────────────────────────────────────────
step "3/6  Monitoring Prometheus metrics (30s window)"

PROM_URL="http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090"
info "Checking error rate metrics every 10s..."

for i in 1 2 3; do
  sleep 10
  ERROR_RATE=$(kubectl exec -n monitoring deploy/kube-prometheus-stack-prometheus -- \
    wget -qO- "${PROM_URL}/api/v1/query?query=sum(rate(order_requests_total{status=~\"5..\"}[1m]))" \
    2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data']['result'][0]['value'][1] if d['data']['result'] else '0')" 2>/dev/null || echo "n/a")
  info "  [${i}/3] order-service 5xx rate: ${ERROR_RATE}"
done

# ── 4. Check SQS for anomaly events ───────────────────────────────────────────
step "4/6  Checking SQS for anomaly events"

SQS_URL="https://sqs.${REGION}.amazonaws.com/${ACCOUNT}/intelliops-anomalies"
info "Polling SQS queue: ${SQS_URL}"
sleep 5

MSG_COUNT=$(aws sqs get-queue-attributes \
  --queue-url "${SQS_URL}" \
  --attribute-names ApproximateNumberOfMessages \
  --query 'Attributes.ApproximateNumberOfMessages' \
  --output text --region "${REGION}" 2>/dev/null || echo "0")

if [ "${MSG_COUNT}" != "0" ] && [ "${MSG_COUNT}" != "N/A" ]; then
  success "SQS has ${MSG_COUNT} anomaly message(s) — anomaly-detector is working!"
else
  warn "SQS has 0 messages — anomaly-detector may not have fired yet (check logs below)"
  kubectl logs -n aiops-demo deploy/anomaly-detector --tail=20 2>/dev/null || true
fi

# ── 5. Check ai-agent activity ────────────────────────────────────────────────
step "5/6  Checking ai-agent for RCA activity"

info "Recent ai-agent logs:"
kubectl logs -n aiops-demo deploy/ai-agent --tail=30 2>/dev/null || warn "ai-agent not running"

# ── 6. Recovery ───────────────────────────────────────────────────────────────
step "6/6  Recovery and summary"

info "Stopping chaos engine..."
kubectl patch chaosengine "${ENGINE_NAME}" -n "${NAMESPACE}" \
  --type=merge -p '{"spec":{"engineState":"stop"}}' 2>/dev/null || true

# Reset service chaos endpoints
case "${SCENARIO}" in
  order|network)
    kubectl exec -n apps deploy/order-service -- \
      curl -s -X DELETE "http://localhost:${PORT}/chaos/slow" &>/dev/null || true ;;
  payment)
    kubectl exec -n apps deploy/payment-service -- \
      curl -s -X DELETE "http://localhost:${PORT}/chaos/cpu" &>/dev/null || true ;;
  inventory)
    kubectl exec -n apps deploy/inventory-service -- \
      curl -s -X DELETE "http://localhost:${PORT}/chaos/disk-stress" &>/dev/null || true ;;
esac

success "Chaos stopped — services recovering"

echo ""
echo -e "${BOLD}══ Demo Complete — Results ══${NC}"
echo ""
echo -e "  Scenario     : ${BOLD}${SCENARIO}${NC}"
echo -e "  SQS messages : ${BOLD}${MSG_COUNT:-0}${NC}"
echo ""
echo -e "  ${BOLD}Grafana Dashboards${NC}"
echo -e "    Services  : https://grafana.infrastructurepath.online/d/services-overview"
echo -e "    SLO       : https://grafana.infrastructurepath.online/d/slo-error-budget"
echo -e "  ${BOLD}ArgoCD${NC}         : https://argocd.infrastructurepath.online"
echo -e "  ${BOLD}LitmusChaos${NC}    : kubectl port-forward svc/litmus-frontend-service 9091:9091 -n litmus"
echo ""
info "To run all 4 scenarios: for s in order payment inventory network; do ./scripts/demo-chaos.sh \$s; done"
