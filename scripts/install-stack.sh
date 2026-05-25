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

for ns in cert-manager external-secrets linkerd database monitoring argocd kong sonarqube falco; do
  if kubectl get namespace "${ns}" &>/dev/null; then
    warn "Namespace ${ns} already exists"
  else
    kubectl create namespace "${ns}"
    success "Created namespace: ${ns}"
  fi
done

# ─── 1. cert-manager ──────────────────────────────────────────────────────────
step "1/15  cert-manager"
helm_install cert-manager cert-manager \
  "${CHARTS}/cert-manager" \
  -f "${VALUES}/cert-manager-values.yaml" \
  --set installCRDs=true

# ─── 2. external-secrets ──────────────────────────────────────────────────────
step "2/15  external-secrets"
helm_install external-secrets external-secrets \
  "${CHARTS}/external-secrets" \
  -f "${VALUES}/external-secrets-values.yaml"

# ─── 3. ExternalSecret manifests + wait for sync ─────────────────────────────
step "3/15  Apply ExternalSecret manifests"

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

info "Waiting 60 s for secrets to sync from AWS Secrets Manager ..."
sleep 60

info "Checking ExternalSecret status ..."
kubectl get externalsecret -A 2>/dev/null || true

# ─── 4. postgresql ────────────────────────────────────────────────────────────
step "4/15  postgresql"
helm_install postgresql database \
  "${CHARTS}/postgresql" \
  -f "${VALUES}/postgresql-values.yaml"

# ─── 5. aws-load-balancer-controller ─────────────────────────────────────────
step "5/15  aws-load-balancer-controller"
helm_install aws-load-balancer-controller kube-system \
  "${CHARTS}/aws-load-balancer-controller" \
  -f "${VALUES}/aws-lb-controller-values.yaml"

# ─── 6. linkerd-crds ─────────────────────────────────────────────────────────
step "6/15  linkerd-crds"
helm_install linkerd-crds linkerd \
  "${CHARTS}/linkerd-crds"

# ─── 6b. linkerd-identity-issuer secret ──────────────────────────────────────
# Linkerd reads issuer certs from a pre-existing k8s TLS secret.
# Certs are stored in Secrets Manager (intelliops/dev/linkerd) as base64 fields.
step "6b/15  linkerd-identity-issuer secret"

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

# ─── 7. linkerd-control-plane ────────────────────────────────────────────────
step "7/15  linkerd-control-plane"
helm_install linkerd-control-plane linkerd \
  "${CHARTS}/linkerd-control-plane" \
  -f "${VALUES}/linkerd-control-plane-values.yaml"

# ─── 8. argocd ───────────────────────────────────────────────────────────────
step "8/15  argocd"
helm_install argocd argocd \
  "${CHARTS}/argo-cd" \
  -f "${VALUES}/argocd-values.yaml"

# ─── 9. kube-prometheus-stack ────────────────────────────────────────────────
step "9/15  kube-prometheus-stack"
helm_install kube-prometheus-stack monitoring \
  "${CHARTS}/kube-prometheus-stack" \
  -f "${VALUES}/kube-prometheus-values.yaml" \
  --timeout 10m

# ─── 10. loki ────────────────────────────────────────────────────────────────
step "10/15  loki"
helm_install loki monitoring \
  "${CHARTS}/loki-stack" \
  -f "${VALUES}/loki-values.yaml"

# ─── 11. tempo ───────────────────────────────────────────────────────────────
step "11/15  tempo"
helm_install tempo monitoring \
  "${CHARTS}/tempo" \
  -f "${VALUES}/tempo-values.yaml"

# ─── 12. otel-collector ──────────────────────────────────────────────────────
step "12/15  otel-collector"
helm_install otel-collector monitoring \
  "${CHARTS}/opentelemetry-collector" \
  -f "${VALUES}/otel-collector-values.yaml"

# ─── 13. kong ────────────────────────────────────────────────────────────────
step "13/15  kong"
helm_install kong kong \
  "${CHARTS}/kong" \
  -f "${VALUES}/kong-values.yaml"

# ─── 14. falco ───────────────────────────────────────────────────────────────
step "14/15  falco"
helm_install falco falco \
  "${CHARTS}/falco" \
  -f "${VALUES}/falco-values.yaml"

# ─── 15. sonarqube ───────────────────────────────────────────────────────────
step "15/15  sonarqube"
helm_install sonarqube sonarqube \
  "${CHARTS}/sonarqube" \
  -f "${VALUES}/sonarqube-values.yaml" \
  --timeout 10m

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
success "Stack installation complete"
