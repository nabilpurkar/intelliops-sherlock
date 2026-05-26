#!/usr/bin/env bash
set -euo pipefail

# ─── Colours ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[SKIP]${NC}  $*"; }
step()    { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${NC}"; \
            echo -e "${BOLD}${CYAN}  $*${NC}"; \
            echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ─── Repo root ────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHARTS="${REPO_ROOT}/k8s/helm-charts"
VALUES="${REPO_ROOT}/k8s/helm-values"
MANIFESTS="${REPO_ROOT}/k8s/external-secrets"
INGRESS="${REPO_ROOT}/k8s/ingress"

# ─── Helpers ──────────────────────────────────────────────────────────────────
helm_install() {
  local release=$1 namespace=$2 chart=$3
  shift 3

  if helm status "${release}" -n "${namespace}" &>/dev/null; then
    warn "${release} already installed in ${namespace} — skipping"
    return 0
  fi

  info "Installing ${release} → ${namespace} ..."
  helm upgrade --install "${release}" "${chart}" \
    --namespace "${namespace}" \
    --create-namespace \
    --wait \
    "$@"
  success "${release} installed"
}

# ─── Pre-flight ───────────────────────────────────────────────────────────────
step "Pre-flight checks"

command -v helm    &>/dev/null || die "helm not found in PATH"
command -v kubectl &>/dev/null || die "kubectl not found in PATH"
command -v aws     &>/dev/null || die "aws CLI not found in PATH"
command -v python3 &>/dev/null || die "python3 not found in PATH"

kubectl cluster-info &>/dev/null || die "kubectl cannot reach the cluster — run: aws eks update-kubeconfig --name intelliops-dev --region us-east-1"

info "Cluster reachable"
info "Charts dir : ${CHARTS}"
info "Values dir : ${VALUES}"

# ─── Pre-create namespaces ────────────────────────────────────────────────────
# Namespaces must exist before ExternalSecrets are applied so ESO can sync
# secrets into them immediately without waiting for Helm --create-namespace.
step "Pre-creating namespaces"

for ns in cert-manager external-secrets linkerd database monitoring argocd kong sonarqube falco external-dns apps locust defectdojo kyverno gatekeeper-system backstage litmus aiops-demo; do
  if kubectl get namespace "${ns}" &>/dev/null; then
    warn "Namespace ${ns} already exists"
  else
    kubectl create namespace "${ns}"
    success "Created namespace: ${ns}"
  fi
done

# ─── 1. cert-manager ──────────────────────────────────────────────────────────
step "1/19  cert-manager"
helm_install cert-manager cert-manager \
  "${CHARTS}/cert-manager" \
  -f "${VALUES}/cert-manager-values.yaml" \
  --set installCRDs=true

# ─── 2. external-secrets ──────────────────────────────────────────────────────
step "2/19  external-secrets"
helm_install external-secrets external-secrets \
  "${CHARTS}/external-secrets" \
  -f "${VALUES}/external-secrets-values.yaml"

# ─── 3. ExternalSecret manifests + wait for sync ─────────────────────────────
step "3/19  Apply ExternalSecret manifests"

info "Waiting for ESO CRDs to be established ..."
kubectl wait --for condition=established --timeout=60s \
  crd/clustersecretstores.external-secrets.io \
  crd/externalsecrets.external-secrets.io

info "Refreshing kubectl API discovery cache ..."
kubectl api-resources --api-group=external-secrets.io > /dev/null 2>&1 || true
sleep 5

info "Applying ClusterSecretStore ..."
kubectl apply -f "${MANIFESTS}/secret-store.yaml"

info "Applying ExternalSecrets ..."
kubectl apply -f "${MANIFESTS}/postgresql-secret.yaml"
kubectl apply -f "${MANIFESTS}/postgresql-initdb-secret.yaml"
kubectl apply -f "${MANIFESTS}/grafana-secret.yaml"
kubectl apply -f "${MANIFESTS}/argocd-secret.yaml"
kubectl apply -f "${MANIFESTS}/kong-secret.yaml"
kubectl apply -f "${MANIFESTS}/sonarqube-secret.yaml"
kubectl apply -f "${MANIFESTS}/defectdojo-secret.yaml"
kubectl apply -f "${MANIFESTS}/falco-defectdojo-secret.yaml"

info "Waiting 60 s for secrets to sync from AWS Secrets Manager ..."
sleep 60

info "Checking ExternalSecret status ..."
kubectl get externalsecret -A 2>/dev/null || true

# ─── 4. postgresql ────────────────────────────────────────────────────────────
step "4/19  postgresql"
helm_install postgresql database \
  "${CHARTS}/postgresql" \
  -f "${VALUES}/postgresql-values.yaml"

# ─── 5. aws-load-balancer-controller ─────────────────────────────────────────
step "5/19  aws-load-balancer-controller"

# Resolve VPC ID at runtime — avoids hardcoding a value that changes on recreate.
# IMDS hop limit is 1 (pods can't reach it), so the controller can't auto-discover.
ALB_VPC_ID=$(aws eks describe-cluster \
  --name intelliops-dev \
  --query 'cluster.resourcesVpcConfig.vpcId' \
  --output text 2>/dev/null) || die "Failed to resolve VPC ID from EKS cluster"
info "ALB controller VPC ID: ${ALB_VPC_ID}"

helm_install aws-load-balancer-controller kube-system \
  "${CHARTS}/aws-load-balancer-controller" \
  -f "${VALUES}/aws-lb-controller-values.yaml" \
  --set vpcId="${ALB_VPC_ID}"

# ─── 6. metrics-server ───────────────────────────────────────────────────────
step "6/19  metrics-server"
helm_install metrics-server kube-system \
  "${CHARTS}/metrics-server" \
  -f "${VALUES}/metrics-server-values.yaml"

# ─── 7. cluster-autoscaler ───────────────────────────────────────────────────
step "7/19  cluster-autoscaler"
helm_install cluster-autoscaler kube-system \
  "${CHARTS}/cluster-autoscaler" \
  -f "${VALUES}/cluster-autoscaler-values.yaml"

# ─── 8. external-dns ─────────────────────────────────────────────────────────
step "8/19  external-dns"
helm_install external-dns external-dns \
  "${CHARTS}/external-dns" \
  -f "${VALUES}/external-dns-values.yaml"

# ─── 9. linkerd-crds ─────────────────────────────────────────────────────────
step "9/19  linkerd-crds"
helm_install linkerd-crds linkerd \
  "${CHARTS}/linkerd-crds"

# ─── 9b. linkerd-identity-issuer secret ──────────────────────────────────────
# Linkerd reads issuer certs from a pre-existing k8s TLS secret.
# Certs are stored in Secrets Manager (intelliops/dev/linkerd) as base64 fields.
step "9b/19  linkerd-identity-issuer secret"

if kubectl get secret linkerd-identity-issuer -n linkerd &>/dev/null; then
  warn "linkerd-identity-issuer already exists — skipping"
else
  info "Fetching Linkerd issuer certs from AWS Secrets Manager ..."
  LINKERD_JSON=$(aws secretsmanager get-secret-value \
    --secret-id intelliops/dev/linkerd \
    --query SecretString --output text)

  ISSUER_CRT=$(echo "${LINKERD_JSON}" | python3 -c \
    "import sys,json,base64; d=json.load(sys.stdin); print(base64.b64decode(d['issuer_crt']).decode())")
  ISSUER_KEY=$(echo "${LINKERD_JSON}" | python3 -c \
    "import sys,json,base64; d=json.load(sys.stdin); print(base64.b64decode(d['issuer_key']).decode())")

  kubectl create secret tls linkerd-identity-issuer \
    --namespace linkerd \
    --cert=<(echo "${ISSUER_CRT}") \
    --key=<(echo "${ISSUER_KEY}")

  success "linkerd-identity-issuer created"
fi

# ─── 10. linkerd-control-plane ───────────────────────────────────────────────
step "10/19  linkerd-control-plane"
helm_install linkerd-control-plane linkerd \
  "${CHARTS}/linkerd-control-plane" \
  -f "${VALUES}/linkerd-control-plane-values.yaml"

# ─── 11. argocd ──────────────────────────────────────────────────────────────
step "11/19  argocd"
helm_install argocd argocd \
  "${CHARTS}/argo-cd" \
  -f "${VALUES}/argocd-values.yaml"

# ─── 12. kube-prometheus-stack ───────────────────────────────────────────────
step "12/19  kube-prometheus-stack"
helm_install kube-prometheus-stack monitoring \
  "${CHARTS}/kube-prometheus-stack" \
  -f "${VALUES}/kube-prometheus-values.yaml" \
  --timeout 10m

# ─── 13. loki ────────────────────────────────────────────────────────────────
step "13/19  loki"
helm_install loki monitoring \
  "${CHARTS}/loki-stack" \
  -f "${VALUES}/loki-values.yaml"

# ─── 14. tempo ───────────────────────────────────────────────────────────────
step "14/19  tempo"
helm_install tempo monitoring \
  "${CHARTS}/tempo" \
  -f "${VALUES}/tempo-values.yaml"

# ─── 15. otel-collector ──────────────────────────────────────────────────────
step "15/19  otel-collector"
helm_install otel-collector monitoring \
  "${CHARTS}/opentelemetry-collector" \
  -f "${VALUES}/otel-collector-values.yaml"

# ─── 16. kong ────────────────────────────────────────────────────────────────
step "16/19  kong"
helm_install kong kong \
  "${CHARTS}/kong" \
  -f "${VALUES}/kong-values.yaml"

# ─── 16b. Kong IngressClass + ingress routes ─────────────────────────────────
step "16b/19  Kong IngressClass + service ingresses"

info "Applying Kong IngressClass ..."
kubectl apply -f "${INGRESS}/kong-ingress-class.yaml"

info "Applying ALB gateway ingress (ExternalDNS wildcard) ..."
kubectl apply -f "${INGRESS}/ingress-kong-gateway.yaml"

info "Applying service ingress routes ..."
kubectl apply -f "${INGRESS}/ingress-argocd.yaml"
kubectl apply -f "${INGRESS}/ingress-grafana.yaml"
kubectl apply -f "${INGRESS}/ingress-prometheus.yaml"
kubectl apply -f "${INGRESS}/ingress-alertmanager.yaml"
kubectl apply -f "${INGRESS}/ingress-sonarqube.yaml"
kubectl apply -f "${INGRESS}/ingress-apps.yaml"
kubectl apply -f "${INGRESS}/ingress-locust.yaml"
kubectl apply -f "${INGRESS}/ingress-kong-admin.yaml"
kubectl apply -f "${INGRESS}/ingress-defectdojo.yaml"

success "IngressClass and all service ingresses applied"

# ─── 16c. ArgoCD AppProject + Applications ────────────────────────────────────
step "16c/19  ArgoCD AppProject + Applications"

info "Applying ArgoCD AppProject ..."
kubectl apply -f "${REPO_ROOT}/k8s/argocd/project.yaml"

info "Applying ArgoCD Applications (microservices + locust) ..."
kubectl apply -f "${REPO_ROOT}/k8s/argocd/microservices-app.yaml"
kubectl apply -f "${REPO_ROOT}/k8s/argocd/locust-app.yaml"

success "ArgoCD Applications registered — they will sync k8s/apps/ and k8s/load-generator/ automatically"

# ─── 17. falco ───────────────────────────────────────────────────────────────
step "17/22  falco"
helm_install falco falco \
  "${CHARTS}/falco" \
  -f "${VALUES}/falco-values.yaml"

# ─── 18. sonarqube ───────────────────────────────────────────────────────────
step "18/22  sonarqube"
helm_install sonarqube sonarqube \
  "${CHARTS}/sonarqube" \
  -f "${VALUES}/sonarqube-values.yaml" \
  --timeout 10m

# ─── 19. defectdojo ──────────────────────────────────────────────────────────
step "19/22  defectdojo"
helm_install defectdojo defectdojo \
  "${CHARTS}/defectdojo" \
  -f "${VALUES}/defectdojo-values.yaml" \
  --timeout 15m

# ─── 20. kyverno ─────────────────────────────────────────────────────────────
step "20/22  kyverno"
helm_install kyverno kyverno \
  "${CHARTS}/kyverno-3.8.1.tgz" \
  -f "${VALUES}/kyverno-values.yaml"

info "Applying Kyverno policies (Audit mode — violations reported, not blocked) ..."
kubectl apply -f "${REPO_ROOT}/k8s/kyverno-policies/"
success "Kyverno policies applied"

# ─── 21. gatekeeper (OPA) ────────────────────────────────────────────────────
step "21/22  gatekeeper (OPA)"
helm_install gatekeeper gatekeeper-system \
  "${CHARTS}/gatekeeper-3.22.2.tgz" \
  -f "${VALUES}/gatekeeper-values.yaml"

info "Waiting 30 s for Gatekeeper webhooks to be ready ..."
sleep 30

info "Applying Gatekeeper ConstraintTemplates ..."
kubectl apply -f "${REPO_ROOT}/k8s/gatekeeper/allowed-registries-template.yaml"
kubectl apply -f "${REPO_ROOT}/k8s/gatekeeper/require-labels-template.yaml"

info "Waiting 10 s for CRDs to be registered ..."
sleep 10

info "Applying Gatekeeper Constraints (warn mode — violations logged, not blocked) ..."
kubectl apply -f "${REPO_ROOT}/k8s/gatekeeper/allowed-registries-constraint.yaml"
kubectl apply -f "${REPO_ROOT}/k8s/gatekeeper/require-labels-constraint.yaml"
success "Gatekeeper constraints applied"

# ─── 22. Prometheus Pushgateway (DORA metrics receiver) ──────────────────────
step "22/25  prometheus-pushgateway (DORA metrics)"
helm_install prometheus-pushgateway monitoring \
  prometheus-community/prometheus-pushgateway \
  -f "${VALUES}/pushgateway-values.yaml"
success "Pushgateway installed — CI will push DORA metrics here after each deployment"
info "Add secret PUSHGATEWAY_URL=http://prometheus-pushgateway.monitoring.svc.cluster.local:9091 to GitHub"

# ─── 23. OpenCost (Kubernetes cost monitoring) ────────────────────────────────
step "23/25  opencost (FinOps)"
helm repo add opencost https://opencost.github.io/opencost-helm-chart 2>/dev/null || true
helm repo update opencost 2>/dev/null || true
helm_install opencost monitoring \
  opencost/opencost \
  -f "${VALUES}/opencost-values.yaml"
success "OpenCost installed — cost metrics available in Grafana cost dashboard"

# ─── 24. Application SLOs + Error Budget rules ────────────────────────────────
step "24/25  SLO recording rules + alerts"
kubectl apply -f "${REPO_ROOT}/k8s/slos/"
success "PrometheusRule SLOs applied (order/payment/inventory — 99.9% availability SLO)"

# ─── 25. Grafana dashboards provisioning ──────────────────────────────────────
step "25/28  Grafana dashboards"
kubectl apply -f "${REPO_ROOT}/k8s/grafana/"
success "Grafana dashboard ConfigMaps applied — sidecar will provision them automatically"
info "Dashboards: Services Overview, SLO/Error Budget, DORA Metrics, Security/GRC, Cost"

# ─── 26. Backstage IDP ────────────────────────────────────────────────────────
step "26/28  Backstage IDP"

info "Adding backstage helm repo ..."
helm repo add backstage https://backstage.github.io/charts 2>/dev/null || true
helm repo update backstage 2>/dev/null || true

info "Applying Backstage ExternalSecret (reads intelliops/dev/backstage → github_token) ..."
kubectl apply -f "${MANIFESTS}/backstage-secret.yaml"

info "Installing Backstage ..."
helm_install backstage backstage \
  backstage/backstage \
  -f "${VALUES}/backstage-values.yaml" \
  --timeout 5m

info "Applying Backstage ingress ..."
kubectl apply -f "${INGRESS}/ingress-backstage.yaml"
success "Backstage installed — https://backstage.infrastructurepath.online (may take 2–3 min to initialise)"
info "Populate intelliops/dev/backstage → github_token in AWS SM before ExternalSecret can sync"

# ─── 27. LitmusChaos ─────────────────────────────────────────────────────────
step "27/28  LitmusChaos (chaos engineering)"

info "Adding litmuschaos helm repo ..."
helm repo add litmuschaos https://litmuschaos.github.io/litmus-helm/ 2>/dev/null || true
helm repo update litmuschaos 2>/dev/null || true

helm_install litmus litmus \
  litmuschaos/litmus \
  -f "${VALUES}/litmus-values.yaml" \
  --timeout 5m

success "LitmusChaos installed — portal at http://localhost:9091 (port-forward: kubectl port-forward svc/litmus-frontend-service 9091:9091 -n litmus)"
info "Chaos experiments: ${REPO_ROOT}/aiops/chaos/"
info "Apply experiments ONLY when deliberately running chaos: kubectl apply -f aiops/chaos/<experiment>.yaml"

# ─── 28. AIOps workloads (namespace + config + deployments) ──────────────────
step "28/28  AIOps workloads (anomaly-detector, forecaster, alert-correlator, ai-agent)"

info "Applying aiops-config ConfigMap + namespace resources ..."
kubectl apply -f "${REPO_ROOT}/k8s/deployments/anomaly-detector.yaml"

info "Updating aiops-config SQS_QUEUE_URL from Terraform output ..."
SQS_URL=$(cd "${REPO_ROOT}/terraform/environments/dev" && \
  terraform output -raw 2>/dev/null <<< "" || true)
# If terraform CLI unavailable, try AWS directly
if [ -z "${SQS_URL}" ]; then
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
  REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
  SQS_URL="https://sqs.${REGION}.amazonaws.com/${ACCOUNT_ID}/intelliops-anomalies"
fi
if [ -n "${SQS_URL}" ]; then
  kubectl patch configmap aiops-config -n aiops-demo \
    --type merge \
    -p "{\"data\":{\"SQS_QUEUE_URL\":\"${SQS_URL}\"}}" 2>/dev/null || true
  info "SQS URL set to: ${SQS_URL}"
fi

info "Applying forecaster ..."
kubectl apply -f "${REPO_ROOT}/k8s/deployments/forecaster.yaml"

info "Applying alert-correlator ..."
kubectl apply -f "${REPO_ROOT}/k8s/deployments/alert-correlator.yaml"

info "Applying Slack ExternalSecret ..."
kubectl apply -f "${MANIFESTS}/slack-secret.yaml"

info "Applying AI agent ..."
kubectl apply -f "${REPO_ROOT}/k8s/deployments/ai-agent.yaml"

# Annotate ServiceAccounts with IRSA role ARNs from Terraform
AI_AGENT_ROLE=$(aws iam get-role --role-name "intelliops-dev-ai-agent-role" \
  --query Role.Arn --output text 2>/dev/null || echo "")
ANOMALY_ROLE=$(aws iam get-role --role-name "intelliops-dev-anomaly-detector-role" \
  --query Role.Arn --output text 2>/dev/null || echo "")

if [ -n "${AI_AGENT_ROLE}" ]; then
  kubectl annotate serviceaccount ai-agent -n aiops-demo \
    "eks.amazonaws.com/role-arn=${AI_AGENT_ROLE}" --overwrite
  kubectl patch deployment ai-agent -n aiops-demo \
    -p '{"spec":{"template":{"metadata":{"annotations":{"kubectl.kubernetes.io/restartedAt":"'"$(date -u +%FT%TZ)"'"}}}}}' \
    2>/dev/null || true
  success "AI agent IRSA role annotated: ${AI_AGENT_ROLE}"
fi

if [ -n "${ANOMALY_ROLE}" ]; then
  kubectl annotate serviceaccount anomaly-detector -n aiops-demo \
    "eks.amazonaws.com/role-arn=${ANOMALY_ROLE}" --overwrite
  success "Anomaly detector IRSA role annotated: ${ANOMALY_ROLE}"
fi

success "AIOps workloads applied to namespace aiops-demo"
info "Populate intelliops/dev/slack → webhook_url in AWS SM to enable Slack notifications"
info "Models will train on first startup (initContainers) — allow 2–5 min before predictions start"

step "Stack installation complete"
info "Security tools: Kyverno, OPA Gatekeeper, Falco, SonarQube, DefectDojo"
info "CI pipeline:    Semgrep, Trivy, Checkov, Gitleaks, OWASP Dep-Check, Cosign, ZAP, Infracost"
info "Observability:  Prometheus, Grafana, Loki, Tempo, OTEL, OpenCost, Pushgateway"
info "AIOps:          anomaly-detector, forecaster, alert-correlator, ai-agent (Bedrock/Claude)"
info "IDP:            Backstage at https://backstage.infrastructurepath.online"
info "Chaos:          LitmusChaos — apply experiments from aiops/chaos/ manually"

# ─── Verify ───────────────────────────────────────────────────────────────────
step "Verification"

echo ""
info "Pods not in Running/Completed state:"
kubectl get pods -A --no-headers \
  | grep -vE '\s+(Running|Completed|Succeeded)\s+' \
  || echo -e "  ${GREEN}All pods healthy${NC}"

echo ""
info "Installed Helm releases:"
echo -e "${BOLD}$(printf '%-35s %-20s %-10s %s\n' RELEASE NAMESPACE STATUS CHART)${NC}"
helm list -A --no-headers \
  | awk '{printf "%-35s %-20s %-10s %s\n", $1, $2, $5, $9}' \
  | sort

echo ""
info "ArgoCD initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d && echo || true

echo ""
info "ALB hostname (ExternalDNS will point *.infrastructurepath.online here):"
kubectl get ingress kong-gateway -n kong \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null && echo || true

echo ""
success "Stack installation complete"

# ─── Auto-configure apps ──────────────────────────────────────────────────────
echo ""
info "Running configure-stack.sh to set up SonarQube, DefectDojo, ArgoCD, Grafana ..."
info "(Pass GITHUB_PAT=ghp_xxx to also push GitHub secrets automatically)"
echo ""
exec "${REPO_ROOT}/scripts/configure-stack.sh"
