#!/usr/bin/env bash
set -euo pipefail

# ─── Colours ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

START_TIME=$(date +%s)

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[SKIP]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step() {
  local _now _elapsed _mm _ss
  _now=$(date +%s)
  _elapsed=$(( _now - START_TIME ))
  _mm=$(( _elapsed / 60 ))
  _ss=$(( _elapsed % 60 ))
  echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${NC}"
  echo -e "${BOLD}${CYAN}  $*${NC}  ${YELLOW}[+${_mm}m${_ss}s]${NC}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}"
}

# ─── Repo root ────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHARTS="${REPO_ROOT}/k8s/helm-charts"
VALUES="${REPO_ROOT}/k8s/helm-values"
MANIFESTS="${REPO_ROOT}/k8s/external-secrets"
INGRESS="${REPO_ROOT}/k8s/ingress"

# ─── Checkpoint / resume ──────────────────────────────────────────────────────
# Each numbered step is saved to .install-state on success.
# Re-running the script skips already-completed steps automatically.
# Usage:
#   bash install-stack.sh           — resume from last checkpoint
#   bash install-stack.sh --reset   — delete checkpoint, start fresh
#   bash install-stack.sh --from 16 — re-run from step 16 onwards
STATE_FILE="${REPO_ROOT}/.install-state"

is_done()   { grep -qxF "step-$1" "${STATE_FILE}" 2>/dev/null; }
mark_done() { echo "step-$1" >> "${STATE_FILE}"; }

# ── Flag parsing ──────────────────────────────────────────────────────────────
_RESET=false
_FROM=""
for _arg in "$@"; do
  case "${_arg}" in
    --reset)
      _RESET=true
      ;;
    --from=*)
      _FROM="${_arg#--from=}"
      ;;
    --from)
      # handled by next arg — not supported in simple loop; use --from=N
      die "Use --from=N (e.g. --from=16), not --from N"
      ;;
    *)
      die "Unknown flag: ${_arg}  (supported: --reset, --from=N)"
      ;;
  esac
done

if ${_RESET}; then
  rm -f "${STATE_FILE}"
  info "State file cleared — starting fresh install"
elif [ -n "${_FROM}" ]; then
  # Remove checkpoint entries for step _FROM and higher from the state file
  if [ -f "${STATE_FILE}" ]; then
    # Build ordered step list; remove entries at or after _FROM
    _ORDERED=(0 1 2 3 4 5 6 7 8 9 9b 10 11 12 12b 13 13a 13b 14 15 15b 16 16b 16c 17 18 19 20 21 22 23 24 25 26 27 28)
    _KEEP=()
    _DROP=false
    for _s in "${_ORDERED[@]}"; do
      [[ "${_s}" == "${_FROM}" ]] && _DROP=true
      ${_DROP} || _KEEP+=("step-${_s}")
    done
    # Rewrite state file keeping only steps before _FROM
    _NEW_STATE=""
    while IFS= read -r _line; do
      for _k in "${_KEEP[@]}"; do
        [[ "${_line}" == "${_k}" ]] && { _NEW_STATE+="${_line}"$'\n'; break; }
      done
    done < "${STATE_FILE}"
    printf '%s' "${_NEW_STATE}" > "${STATE_FILE}"
    info "Checkpoint rewound — will re-run from step ${_FROM} onwards"
  fi
fi

if [ -f "${STATE_FILE}" ]; then
  _DONE_COUNT=$(grep -c . "${STATE_FILE}" 2>/dev/null || echo 0)
  info "Resuming install — ${_DONE_COUNT}/28 steps already completed"
  info "  (run with --reset to start fresh, or --from=N to re-run from step N)"
else
  info "Starting fresh install — progress saved to .install-state"
fi

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

# ─── 0. Bootstrap AWS Secrets Manager ────────────────────────────────────────
# Always runs — each individual secret check is idempotent and fast.
# Terraform creates SM secret containers with NO values. ESO will fail to sync
# any ExternalSecret, and pods that mount those k8s Secrets won't start.
step "0/28  Bootstrap AWS Secrets Manager secrets"

REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")

_sm_has_value() {
  local secret_id=$1 key=$2
  local val
  val=$(aws secretsmanager get-secret-value \
    --secret-id "${secret_id}" --region "${REGION}" \
    --query SecretString --output text 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('${key}',''))" 2>/dev/null || echo "")
  [ -n "${val}" ]
}

_sm_put() {
  local secret_id="$1" secret_string="$2"
  if aws secretsmanager describe-secret --secret-id "${secret_id}" \
      --region "${REGION}" &>/dev/null; then
    aws secretsmanager put-secret-value \
      --secret-id "${secret_id}" --region "${REGION}" \
      --secret-string "${secret_string}" \
      --query VersionId --output text 2>/dev/null
  else
    aws secretsmanager create-secret \
      --name "${secret_id}" --region "${REGION}" \
      --secret-string "${secret_string}" \
      --query ARN --output text 2>/dev/null
  fi
}

# ── postgresql ──────────────────────────────────────────────────────────────
if ! _sm_has_value "intelliops/dev/postgresql" "postgres_password"; then
  info "Seeding intelliops/dev/postgresql ..."
  PG=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)
  SQ=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)
  KG=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)
  DJ=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)
  BS=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)
  SQ_MON=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20)
  _sm_put "intelliops/dev/postgresql" \
    "{\"postgres_password\":\"${PG}\",\"sonarqube_password\":\"${SQ}\",\"kong_password\":\"${KG}\",\"defectdojo_password\":\"${DJ}\",\"backstage_password\":\"${BS}\",\"sonarqube_monitoring_passcode\":\"${SQ_MON}\"}"
  success "intelliops/dev/postgresql seeded"
else
  # Back-fill any keys added after initial seed
  _needs_backfill=0
  if ! _sm_has_value "intelliops/dev/postgresql" "sonarqube_monitoring_passcode"; then
    _needs_backfill=1
  fi
  if ! _sm_has_value "intelliops/dev/postgresql" "backstage_password"; then
    _needs_backfill=1
  fi
  if [ "${_needs_backfill}" -eq 1 ]; then
    info "Back-filling missing keys in intelliops/dev/postgresql ..."
    CURRENT_PG=$(aws secretsmanager get-secret-value \
      --secret-id intelliops/dev/postgresql --region "${REGION}" \
      --query SecretString --output text)
    SQ_MON=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20)
    BS=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)
    UPDATED_PG=$(echo "${CURRENT_PG}" | python3 -c \
      "import sys,json; d=json.load(sys.stdin); \
       d.setdefault('sonarqube_monitoring_passcode','${SQ_MON}'); \
       d.setdefault('backstage_password','${BS}'); \
       print(json.dumps(d))")
    _sm_put "intelliops/dev/postgresql" "${UPDATED_PG}"
    success "intelliops/dev/postgresql back-filled"
  else
    info "intelliops/dev/postgresql — already has values"
  fi
fi

# ── defectdojo ──────────────────────────────────────────────────────────────
if ! _sm_has_value "intelliops/dev/defectdojo" "admin_password"; then
  info "Seeding intelliops/dev/defectdojo ..."
  DJ_PASS=$(aws secretsmanager get-secret-value \
    --secret-id intelliops/dev/postgresql --region "${REGION}" \
    --query SecretString --output text \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['defectdojo_password'])")
  DJ_SK=$(openssl rand -base64 32)
  DJ_AES=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 32)
  DJ_METRICS=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20)
  DJ_VALKEY=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)
  _sm_put "intelliops/dev/defectdojo" \
    "{\"admin_password\":\"${DJ_PASS}\",\"secret_key\":\"${DJ_SK}\",\"credential_aes256_key\":\"${DJ_AES}\",\"metrics_http_auth_password\":\"${DJ_METRICS}\",\"valkey_password\":\"${DJ_VALKEY}\"}"
  success "intelliops/dev/defectdojo seeded"
else
  info "intelliops/dev/defectdojo — already has values"
fi

# ── argocd ──────────────────────────────────────────────────────────────────
if ! _sm_has_value "intelliops/dev/argocd" "admin_password"; then
  info "Seeding intelliops/dev/argocd ..."
  _sm_put "intelliops/dev/argocd" \
    "{\"admin_password\":\"$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)\"}"
  success "intelliops/dev/argocd seeded"
else
  info "intelliops/dev/argocd — already has values"
fi

# ── grafana ──────────────────────────────────────────────────────────────────
if ! _sm_has_value "intelliops/dev/grafana" "admin_password"; then
  info "Seeding intelliops/dev/grafana ..."
  _sm_put "intelliops/dev/grafana" \
    "{\"admin_password\":\"$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)\"}"
  success "intelliops/dev/grafana seeded"
else
  info "intelliops/dev/grafana — already has values"
fi

# ── sonarqube — must be "admin" (default) so configure-stack.sh can log in ──
if ! _sm_has_value "intelliops/dev/sonarqube" "admin_password"; then
  info "Seeding intelliops/dev/sonarqube (default admin password) ..."
  _sm_put "intelliops/dev/sonarqube" '{"admin_password":"admin"}'
  success "intelliops/dev/sonarqube seeded"
else
  info "intelliops/dev/sonarqube — already has values"
fi

# ── litmus MongoDB ───────────────────────────────────────────────────────────
if ! _sm_has_value "intelliops/dev/litmus" "mongodb_root_password"; then
  info "Seeding intelliops/dev/litmus (MongoDB credentials) ..."
  _sm_put "intelliops/dev/litmus" \
    "{\"mongodb_root_password\":\"$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)\",\"mongodb_root_user\":\"root\"}"
  success "intelliops/dev/litmus seeded"
else
  info "intelliops/dev/litmus — already has values"
fi

# ── backstage — placeholder until a real GitHub token is provided ────────────
if ! _sm_has_value "intelliops/dev/backstage" "github_token"; then
  info "Seeding intelliops/dev/backstage (placeholder — update with real GitHub token) ..."
  _sm_put "intelliops/dev/backstage" '{"github_token":"ghp_placeholder_replace_with_real_token"}'
  success "intelliops/dev/backstage seeded (placeholder)"
else
  info "intelliops/dev/backstage — already has values"
fi

# ── slack — placeholder until a real webhook is provided ────────────────────
if ! _sm_has_value "intelliops/dev/slack" "webhook_url"; then
  info "Seeding intelliops/dev/slack (placeholder — update with real Slack webhook) ..."
  _sm_put "intelliops/dev/slack" '{"webhook_url":"https://hooks.slack.com/services/placeholder"}'
  success "intelliops/dev/slack seeded (placeholder)"
else
  info "intelliops/dev/slack — already has values"
fi

# ── Linkerd PKI — generate certs if SM secret is empty ──────────────────────
if ! _sm_has_value "intelliops/dev/linkerd" "ca_crt_b64"; then
  info "Linkerd PKI not found in SM — generating trust anchor + issuer certs ..."
  # Use env to bypass the step() shell function that shadows the binary
  STEP_BIN=$(env which step 2>/dev/null || echo "/usr/local/bin/step")
  [ -x "${STEP_BIN}" ] || die "step CLI not found at ${STEP_BIN} — install: sudo apt install step-cli"

  TMPDIR_LINKERD=$(mktemp -d)
  trap 'rm -rf "${TMPDIR_LINKERD}"' EXIT

  "${STEP_BIN}" certificate create root.linkerd.cluster.local \
    "${TMPDIR_LINKERD}/ca.crt" "${TMPDIR_LINKERD}/ca.key" \
    --profile root-ca --no-password --insecure \
    --not-after 87600h

  "${STEP_BIN}" certificate create identity.linkerd.cluster.local \
    "${TMPDIR_LINKERD}/issuer.crt" "${TMPDIR_LINKERD}/issuer.key" \
    --profile intermediate-ca --no-password --insecure \
    --ca "${TMPDIR_LINKERD}/ca.crt" --ca-key "${TMPDIR_LINKERD}/ca.key" \
    --not-after 8760h

  CA_B64=$(base64 -w0 "${TMPDIR_LINKERD}/ca.crt")
  ISSUER_CRT_B64=$(base64 -w0 "${TMPDIR_LINKERD}/issuer.crt")
  ISSUER_KEY_B64=$(base64 -w0 "${TMPDIR_LINKERD}/issuer.key")

  _sm_put "intelliops/dev/linkerd" \
    "{\"ca_crt_b64\":\"${CA_B64}\",\"issuer_crt_b64\":\"${ISSUER_CRT_B64}\",\"issuer_key_b64\":\"${ISSUER_KEY_B64}\"}"
  success "Linkerd PKI generated and stored in SM"
else
  info "intelliops/dev/linkerd — PKI already present in SM"
fi

success "All SM secrets bootstrapped"

# ─── Pre-create namespaces ────────────────────────────────────────────────────
# Always runs — idempotent and fast.
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
step "1/28  cert-manager"
is_done "1" || {
  helm_install cert-manager cert-manager \
    "${CHARTS}/cert-manager" \
    -f "${VALUES}/cert-manager-values.yaml" \
    --set installCRDs=true
  mark_done "1"
}

# ─── 2. external-secrets ──────────────────────────────────────────────────────
step "2/28  external-secrets"
is_done "2" || {
  helm_install external-secrets external-secrets \
    "${CHARTS}/external-secrets" \
    -f "${VALUES}/external-secrets-values.yaml"
  mark_done "2"
}

# ─── 3. ExternalSecret manifests + wait for sync ─────────────────────────────
step "3/28  Apply ExternalSecret manifests"
is_done "3" || {
  info "Waiting for ESO CRDs to be established ..."
  kubectl wait --for condition=established --timeout=60s \
    crd/clustersecretstores.external-secrets.io \
    crd/externalsecrets.external-secrets.io

  info "Refreshing kubectl API discovery cache ..."
  kubectl api-resources --api-group=external-secrets.io > /dev/null 2>&1 || true

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

  info "Waiting for ExternalSecrets to sync (poll up to 3 min) ..."
  for _i in $(seq 1 18); do
    not_synced=$(kubectl get externalsecret -A --no-headers 2>/dev/null \
      | grep -cv "True\|SecretSynced" || true)
    total=$(kubectl get externalsecret -A --no-headers 2>/dev/null | wc -l || echo "0")
    info "  [${_i}/18] ${not_synced}/${total} secrets not yet synced"
    [ "${not_synced}" -eq 0 ] && [ "${total}" -gt 0 ] && break
    sleep 10
  done
  kubectl get externalsecret -A 2>/dev/null || true
  mark_done "3"
}

# ─── 4. postgresql ────────────────────────────────────────────────────────────
step "4/28  postgresql"
is_done "4" || {
  helm_install postgresql database \
    "${CHARTS}/postgresql" \
    -f "${VALUES}/postgresql-values.yaml"
  mark_done "4"
}

# ─── 5. aws-load-balancer-controller ─────────────────────────────────────────
step "5/28  aws-load-balancer-controller"
is_done "5" || {
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
  mark_done "5"
}

# ─── 6. metrics-server ───────────────────────────────────────────────────────
step "6/28  metrics-server"
is_done "6" || {
  helm_install metrics-server kube-system \
    "${CHARTS}/metrics-server" \
    -f "${VALUES}/metrics-server-values.yaml"
  mark_done "6"
}

# ─── 7. cluster-autoscaler ───────────────────────────────────────────────────
step "7/28  cluster-autoscaler"
is_done "7" || {
  helm_install cluster-autoscaler kube-system \
    "${CHARTS}/cluster-autoscaler" \
    -f "${VALUES}/cluster-autoscaler-values.yaml"
  mark_done "7"
}

# ─── 8. external-dns ─────────────────────────────────────────────────────────
step "8/28  external-dns"
is_done "8" || {
  helm_install external-dns external-dns \
    "${CHARTS}/external-dns" \
    -f "${VALUES}/external-dns-values.yaml"
  mark_done "8"
}

# ─── 9. linkerd-crds ─────────────────────────────────────────────────────────
step "9/28  linkerd-crds"
is_done "9" || {
  helm_install linkerd-crds linkerd \
    "${CHARTS}/linkerd-crds"
  mark_done "9"
}

# ─── 9b. linkerd-identity-issuer secret + trust anchor ───────────────────────
# Read Linkerd certs from SM unconditionally — step 10 needs LINKERD_CA_CRT
# even when step 9b is already checkpointed and skipped.
LINKERD_JSON=$(aws secretsmanager get-secret-value \
  --secret-id intelliops/dev/linkerd --region "${REGION}" \
  --query SecretString --output text) \
  || die "Failed to read intelliops/dev/linkerd from SM"

LINKERD_CA_CRT=$(echo "${LINKERD_JSON}" | python3 -c \
  "import sys,json,base64; d=json.load(sys.stdin); print(base64.b64decode(d['ca_crt_b64']).decode())")
LINKERD_ISSUER_CRT=$(echo "${LINKERD_JSON}" | python3 -c \
  "import sys,json,base64; d=json.load(sys.stdin); print(base64.b64decode(d['issuer_crt_b64']).decode())")
LINKERD_ISSUER_KEY=$(echo "${LINKERD_JSON}" | python3 -c \
  "import sys,json,base64; d=json.load(sys.stdin); print(base64.b64decode(d['issuer_key_b64']).decode())")

step "9b/28  linkerd-identity-issuer secret"
is_done "9b" || {
  if kubectl get secret linkerd-identity-issuer -n linkerd &>/dev/null; then
    warn "linkerd-identity-issuer already exists — skipping"
  else
    kubectl create secret tls linkerd-identity-issuer \
      --namespace linkerd \
      --cert=<(echo "${LINKERD_ISSUER_CRT}") \
      --key=<(echo "${LINKERD_ISSUER_KEY}")
    success "linkerd-identity-issuer created from SM"
  fi
  mark_done "9b"
}

# ─── 10. linkerd-control-plane ───────────────────────────────────────────────
# Trust anchor is injected at install time from SM — not hardcoded in values file.
step "10/28  linkerd-control-plane"
is_done "10" || {
  helm_install linkerd-control-plane linkerd \
    "${CHARTS}/linkerd-control-plane" \
    -f "${VALUES}/linkerd-control-plane-values.yaml" \
    --set-string "identityTrustAnchorsPEM=${LINKERD_CA_CRT}"
  mark_done "10"
}

# ─── 11. argocd ──────────────────────────────────────────────────────────────
step "11/28  argocd"
is_done "11" || {
  helm_install argocd argocd \
    "${CHARTS}/argo-cd" \
    -f "${VALUES}/argocd-values.yaml"
  mark_done "11"
}

# ─── 12. ArgoCD pre-requisites — secrets that must exist before apps sync ─────
step "12/28  ArgoCD pre-requisites"
is_done "12" || {
  # LitmusChaos: MongoDB credentials secret (chart reads this at startup)
  kubectl create namespace litmus --dry-run=client -o yaml | kubectl apply -f -
  if ! kubectl get secret litmus-mongodb-secret -n litmus &>/dev/null; then
    info "Creating litmus-mongodb-secret from SM (intelliops/dev/litmus) ..."
    LITMUS_JSON=$(aws secretsmanager get-secret-value \
      --secret-id intelliops/dev/litmus --region "${REGION}" \
      --query SecretString --output text)
    LITMUS_MONGO_PASS=$(echo "${LITMUS_JSON}" | python3 -c \
      "import sys,json; print(json.load(sys.stdin)['mongodb_root_password'])")
    kubectl create secret generic litmus-mongodb-secret -n litmus \
      --from-literal=mongodb-root-password="${LITMUS_MONGO_PASS}" \
      --from-literal=mongodb-passwords="${LITMUS_MONGO_PASS}" \
      --from-literal=mongodb-replica-set-key="$(openssl rand -base64 32)" \
      --from-literal=mongodb-metrics-password="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20)"
    success "litmus-mongodb-secret created"
  else
    warn "litmus-mongodb-secret already exists — skipping"
  fi

  # Backstage: ExternalSecrets (GitHub token + PostgreSQL credentials)
  kubectl create namespace backstage --dry-run=client -o yaml | kubectl apply -f -
  info "Applying Backstage ExternalSecrets ..."
  kubectl apply -f "${MANIFESTS}/backstage-secret.yaml"

  mark_done "12"
}

# ─── 12b. Cleanup orphaned loki-promtail DaemonSet from old loki-stack chart ─
step "12b/28  cleanup-loki-stack-promtail"
is_done "12b" || {
  if kubectl get daemonset loki-promtail -n monitoring &>/dev/null; then
    info "Removing orphaned loki-promtail DaemonSet from old loki-stack chart..."
    kubectl delete daemonset loki-promtail -n monitoring 2>&1 || true
    success "loki-promtail DaemonSet removed"
  fi
  mark_done "12b"
}

# ─── 13–16. Placeholder — helm installs replaced by ArgoCD (see 16c) ─────────
# Steps 13/13a/13b/14/15/15b/16 are handled by ArgoCD Applications below.
# Marking done immediately so checkpoint/resume skips them on re-runs.
for _s in 13 13a 13b 14 15 15b 16; do
  is_done "${_s}" || mark_done "${_s}"
done

# ─── 16b. Kong IngressClass + ingress routes ─────────────────────────────────
step "16b/28  Kong IngressClass + service ingresses"
is_done "16b" || {
  info "Applying Kong IngressClass ..."
  kubectl apply -f "${INGRESS}/kong-ingress-class.yaml"

  info "Resolving ACM wildcard certificate ARN from AWS ..."
  ACM_CERT_ARN=$(aws acm list-certificates \
    --certificate-statuses ISSUED \
    --query "CertificateSummaryList[?DomainName=='infrastructurepath.online'].CertificateArn|[0]" \
    --output text --region "${REGION}" 2>/dev/null || echo "")
  [ -n "${ACM_CERT_ARN}" ] && [ "${ACM_CERT_ARN}" != "None" ] \
    || die "ACM wildcard certificate for *.infrastructurepath.online not found — ensure it exists with ISSUED status"
  info "ALB certificate ARN: ${ACM_CERT_ARN}"

  info "Applying ALB gateway ingress (ExternalDNS wildcard) ..."
  sed "s|\${ACM_CERT_ARN}|${ACM_CERT_ARN}|g" \
    "${INGRESS}/ingress-kong-gateway.yaml" | kubectl apply -f -

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
  kubectl apply -f "${INGRESS}/ingress-falco.yaml"
  kubectl apply -f "${INGRESS}/ingress-backstage.yaml"

  success "IngressClass and all service ingresses applied"
  mark_done "16b"
}

# ─── 16c. ArgoCD AppProject + ALL Applications ────────────────────────────────
# All Helm-based tools (monitoring, security, platform) are now managed by ArgoCD.
# ArgoCD uses sync waves (annotations) to deploy in the correct order:
#   wave 0: kyverno, gatekeeper (security baseline)
#   wave 1: prometheus, loki, tempo, otel-collector, falco, kong
#   wave 2: promtail, otel-operator, pushgateway, sonarqube, defectdojo
#   wave 3: opencost, backstage, litmus
step "16c/28  ArgoCD AppProject + ALL Applications"
is_done "16c" || {
  info "Applying ArgoCD AppProject ..."
  kubectl apply -f "${REPO_ROOT}/k8s/argocd/project.yaml"

  info "Applying monitoring Applications ..."
  kubectl apply -Rf "${REPO_ROOT}/k8s/argocd/monitoring/"

  info "Applying security Applications ..."
  kubectl apply -Rf "${REPO_ROOT}/k8s/argocd/security/"

  info "Applying platform Applications ..."
  kubectl apply -Rf "${REPO_ROOT}/k8s/argocd/platform/"

  info "Applying workload Applications (microservices, AIOps, Locust) ..."
  kubectl apply -f "${REPO_ROOT}/k8s/argocd/microservices-app.yaml"
  kubectl apply -f "${REPO_ROOT}/k8s/argocd/aiops-app.yaml"
  kubectl apply -f "${REPO_ROOT}/k8s/argocd/locust-app.yaml"

  success "All ArgoCD Applications registered — syncing asynchronously via sync waves"
  info "Monitor sync status: kubectl get applications -n argocd"
  info "Or: argocd app list (if argocd CLI is installed)"
  mark_done "16c"
}

# ─── 17. Kyverno policies — apply after CRDs are established by ArgoCD ───────
step "17/28  kyverno-policies"
is_done "17" || {
  info "Waiting for Kyverno ClusterPolicy CRD (ArgoCD syncing — up to 5 min) ..."
  kubectl wait --for=condition=established \
    crd/clusterpolicies.kyverno.io --timeout=5m 2>/dev/null || {
    warn "Kyverno CRD not ready in 5 min — applying policies anyway (will retry if ArgoCD re-syncs)"
  }
  info "Applying Kyverno policies ..."
  kubectl apply -f "${REPO_ROOT}/k8s/kyverno-policies/" 2>&1 || \
    warn "Kyverno policies not applied — CRD not ready yet. Re-run: bash install-stack.sh --from=17 once Kyverno is synced"
  success "Kyverno policies applied (or queued for reapply)"
  mark_done "17"
}

# ─── 18–23. Placeholder — helm installs replaced by ArgoCD (see 16c) ─────────
for _s in 18 19 22 23; do
  is_done "${_s}" || mark_done "${_s}"
done

# ─── 19. DefectDojo PostgreSQL readiness check — wait before policies apply ──
# (DefectDojo ArgoCD app needs PG ready; we wait here so policies don't block it)
step "19/28  defectdojo-pg-readiness"
is_done "19" || {
  info "Waiting for PostgreSQL to accept connections (poll up to 3 min) ..."
  PG_READY=0
  for _i in $(seq 1 18); do
    if kubectl exec -n database postgresql-0 -- \
        env PGPASSWORD="$(kubectl get secret postgresql-credentials -n database \
          -o jsonpath='{.data.postgres-password}' | base64 -d)" \
        psql -U postgres -c "SELECT 1;" &>/dev/null 2>&1; then
      PG_READY=1; break
    fi
    sleep 10
  done
  if [ "${PG_READY}" -eq 1 ]; then
    success "PostgreSQL is ready — DefectDojo/SonarQube/Backstage ArgoCD apps can proceed"
  else
    warn "PostgreSQL not confirmed ready — DefectDojo may retry; check ArgoCD app status"
  fi
  mark_done "19"
}

# ─── 21. Gatekeeper constraints — apply after CRDs are established by ArgoCD ─
step "21/28  gatekeeper-constraints"
is_done "21" || {
  info "Waiting for Gatekeeper ConstraintTemplate CRD (ArgoCD syncing — up to 5 min) ..."
  kubectl wait --for=condition=established \
    crd/constrainttemplates.templates.gatekeeper.sh --timeout=5m 2>/dev/null || {
    warn "Gatekeeper CRD not ready in 5 min — applying templates anyway"
  }

  info "Applying Gatekeeper ConstraintTemplates ..."
  kubectl apply -f "${REPO_ROOT}/k8s/gatekeeper/allowed-registries-template.yaml" 2>&1 || \
    warn "Gatekeeper ConstraintTemplate not applied — CRD not ready yet"
  kubectl apply -f "${REPO_ROOT}/k8s/gatekeeper/require-labels-template.yaml" 2>&1 || \
    warn "Gatekeeper ConstraintTemplate not applied — CRD not ready yet"

  info "Waiting for ConstraintTemplate CRDs to be established ..."
  for _i in $(seq 1 12); do
    ready=$(kubectl get crd 2>/dev/null \
      | grep -c "allowedregistries\|requirelabels" || true)
    [ "${ready}" -ge 2 ] && break
    sleep 10
  done

  info "Applying Gatekeeper Constraints (warn mode — violations logged, not blocked) ..."
  kubectl apply -f "${REPO_ROOT}/k8s/gatekeeper/allowed-registries-constraint.yaml" 2>&1 || \
    warn "Gatekeeper Constraint not applied — CRD not ready yet. Re-run: bash install-stack.sh --from=21"
  kubectl apply -f "${REPO_ROOT}/k8s/gatekeeper/require-labels-constraint.yaml" 2>&1 || \
    warn "Gatekeeper Constraint not applied — CRD not ready yet. Re-run: bash install-stack.sh --from=21"
  success "Gatekeeper constraints applied (or queued for reapply)"
  mark_done "21"
}

# ─── 24. Application SLOs + Error Budget rules ────────────────────────────────
step "24/28  SLO recording rules + alerts"
is_done "24" || {
  # Wait for PrometheusRule CRD (Prometheus deployed by ArgoCD wave 1)
  kubectl wait --for=condition=established crd/prometheusrules.monitoring.coreos.com \
    --timeout=5m 2>/dev/null || warn "PrometheusRule CRD not ready — SLOs may need reapply"
  kubectl apply -f "${REPO_ROOT}/k8s/slos/" 2>&1 || \
    warn "SLO PrometheusRules not applied — CRD not ready. Re-run: bash install-stack.sh --from=24"
  success "PrometheusRule SLOs applied (order/payment/inventory — 99.9% availability SLO)"

  info "Applying ServiceMonitors for microservice metrics scraping ..."
  kubectl wait --for=condition=established crd/servicemonitors.monitoring.coreos.com \
    --timeout=2m 2>/dev/null || warn "ServiceMonitor CRD not ready"
  kubectl apply -f "${REPO_ROOT}/k8s/apps/servicemonitors.yaml" 2>&1 || \
    warn "ServiceMonitors not applied — CRD not ready. Re-run: bash install-stack.sh --from=24"
  success "ServiceMonitors applied — Prometheus will scrape order/payment/inventory /metrics"
  mark_done "24"
}

# ─── 25. Grafana dashboards provisioning ──────────────────────────────────────
step "25/28  Grafana dashboards"
is_done "25" || {
  kubectl apply -f "${REPO_ROOT}/k8s/grafana/"
  success "Grafana dashboard ConfigMaps applied — sidecar will provision them automatically"
  info "Dashboards: Services Overview, SLO/Error Budget, DORA Metrics, Security/GRC, Cost"
  mark_done "25"
}

# ─── 26–27. Placeholder — backstage/litmus handled by ArgoCD (see 16c) ───────
# Backstage: ArgoCD backstage-app.yaml; ExternalSecrets applied in step 12
# LitmusChaos: ArgoCD litmus-app.yaml; MongoDB secret created in step 12
for _s in 26 27; do
  is_done "${_s}" || {
    info "Step ${_s}: managed by ArgoCD — skipping helm install"
    mark_done "${_s}"
  }
done

# ─── 12b-post. Patch Grafana datasource ConfigMap (lokiSearch Tempo→Loki) ─────
# Runs after ArgoCD has had time to deploy prometheus stack (async — best effort)
step "12b-post/28  grafana-datasource-patch"
is_done "12b-post" || {
  CM=$(kubectl get configmap -n monitoring -o name 2>/dev/null | grep grafana-datasource | head -1)
  if [ -n "${CM}" ]; then
    PATCH_NEEDED=$(kubectl get "${CM}" -n monitoring \
      -o jsonpath='{.data.datasource\.yaml}' 2>/dev/null | grep -c "lokiSearch" || true)
    if [ "${PATCH_NEEDED}" = "0" ]; then
      info "Patching Grafana datasource ConfigMap to add lokiSearch for Tempo..."
      kubectl get "${CM}" -n monitoring -o json | \
        python3 -c "
import sys, json
d = json.load(sys.stdin)
yaml_str = d['data']['datasource.yaml']
yaml_str = yaml_str.replace(
  'nodeGraph:\n      enabled: true',
  'lokiSearch:\n      datasourceUid: Loki\n    nodeGraph:\n      enabled: true'
)
d['data']['datasource.yaml'] = yaml_str
print(json.dumps(d))
" | kubectl apply -f - 2>&1
      success "Grafana datasource ConfigMap patched with lokiSearch"
    else
      warn "Grafana datasource ConfigMap already has lokiSearch — skipping"
    fi
  else
    warn "Grafana datasource ConfigMap not found yet — ArgoCD may still be syncing"
  fi
  mark_done "12b-post"
}

# ─── 28. AIOps pre-requisites — ExternalSecrets not managed by ArgoCD ─────────
# AIOps deployments (k8s/deployments/) are managed by ArgoCD aiops-app.yaml.
# IRSA ARNs and SQS URL are embedded in manifests — no kubectl annotate needed.
step "28/28  AIOps pre-requisites"
is_done "28" || {
  info "Applying Slack ExternalSecret (reads intelliops/dev/slack → webhook_url) ..."
  kubectl create namespace aiops-demo --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f "${MANIFESTS}/slack-secret.yaml"
  success "Slack ExternalSecret applied — populate intelliops/dev/slack → webhook_url in SM for notifications"
  info "AIOps deployments managed by ArgoCD (aiops-app.yaml) — models train on first startup (~2–5 min)"
  mark_done "28"
}

_TOTAL=$(( $(date +%s) - START_TIME ))
step "Stack installation complete — total time: $(( _TOTAL / 60 ))m$(( _TOTAL % 60 ))s"
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
