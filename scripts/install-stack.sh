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
  SQ_MON=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20)
  _sm_put "intelliops/dev/postgresql" \
    "{\"postgres_password\":\"${PG}\",\"sonarqube_password\":\"${SQ}\",\"kong_password\":\"${KG}\",\"defectdojo_password\":\"${DJ}\",\"sonarqube_monitoring_passcode\":\"${SQ_MON}\"}"
  success "intelliops/dev/postgresql seeded"
else
  # Ensure sonarqube_monitoring_passcode exists (added later — backfill if missing)
  if ! _sm_has_value "intelliops/dev/postgresql" "sonarqube_monitoring_passcode"; then
    info "Back-filling sonarqube_monitoring_passcode in intelliops/dev/postgresql ..."
    CURRENT_PG=$(aws secretsmanager get-secret-value \
      --secret-id intelliops/dev/postgresql --region "${REGION}" \
      --query SecretString --output text)
    SQ_MON=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20)
    UPDATED_PG=$(echo "${CURRENT_PG}" | python3 -c \
      "import sys,json; d=json.load(sys.stdin); d['sonarqube_monitoring_passcode']='${SQ_MON}'; print(json.dumps(d))")
    _sm_put "intelliops/dev/postgresql" "${UPDATED_PG}"
    success "sonarqube_monitoring_passcode back-filled"
  fi
  info "intelliops/dev/postgresql — already has values"
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

# ─── 12. kube-prometheus-stack ───────────────────────────────────────────────
step "12/28  kube-prometheus-stack"
is_done "12" || {
  helm_install kube-prometheus-stack monitoring \
    "${CHARTS}/kube-prometheus-stack" \
    -f "${VALUES}/kube-prometheus-values.yaml" \
    --timeout 10m
  mark_done "12"
}

# ─── 12b. Patch Grafana datasource ConfigMap (add lokiSearch link Tempo→Loki) ─
step "12b/28  grafana-datasource-patch"
is_done "12b" || {
  # kube-prometheus-stack upgrade is blocked by Kyverno on its admission Job hooks.
  # Patch the ConfigMap directly instead of re-running helm upgrade.
  CM=$(kubectl get configmap -n monitoring -o name 2>/dev/null | grep grafana-datasource | head -1)
  if [ -n "${CM}" ]; then
    PATCH_NEEDED=$(kubectl get "${CM}" -n monitoring \
      -o jsonpath='{.data.datasource\.yaml}' 2>/dev/null | grep -c "lokiSearch" || true)
    if [ "${PATCH_NEEDED}" = "0" ]; then
      info "Patching Grafana datasource ConfigMap to add lokiSearch for Tempo..."
      kubectl get "${CM}" -n monitoring -o json | \
        python3 -c "
import sys, json, re
d = json.load(sys.stdin)
yaml_str = d['data']['datasource.yaml']
# Insert lokiSearch after nodeGraph block
yaml_str = yaml_str.replace(
  'nodeGraph:\n      enabled: true',
  'lokiSearch:\n      datasourceUid: Loki\n    nodeGraph:\n      enabled: true'
)
d['data']['datasource.yaml'] = yaml_str
print(json.dumps(d))
" | kubectl apply -f - 2>&1
      success "Grafana datasource ConfigMap patched with lokiSearch"
    else
      warn "Grafana datasource ConfigMap already has lokiSearch — skipping patch"
    fi
  fi
  mark_done "12b"
}

# ─── 13. loki ────────────────────────────────────────────────────────────────
step "13/28  loki"
is_done "13" || {
  helm_install loki monitoring \
    "${CHARTS}/loki" \
    -f "${VALUES}/loki-values.yaml"
  mark_done "13"
}

# ─── 13a. cleanup orphaned loki-promtail DaemonSet from old loki-stack chart ─
step "13a/28  cleanup-loki-stack-promtail"
is_done "13a" || {
  if kubectl get daemonset loki-promtail -n monitoring &>/dev/null; then
    info "Removing orphaned loki-promtail DaemonSet from old loki-stack chart..."
    kubectl delete daemonset loki-promtail -n monitoring 2>&1 || true
    success "loki-promtail DaemonSet removed"
  fi
  mark_done "13a"
}

# ─── 13b. promtail ───────────────────────────────────────────────────────────
step "13b/28  promtail"
is_done "13b" || {
  helm_install promtail monitoring \
    "${CHARTS}/promtail" \
    -f "${VALUES}/promtail-values.yaml"
  mark_done "13b"
}

# ─── 14. tempo ───────────────────────────────────────────────────────────────
step "14/28  tempo"
is_done "14" || {
  helm_install tempo monitoring \
    "${CHARTS}/tempo" \
    -f "${VALUES}/tempo-values.yaml"
  mark_done "14"
}

# ─── 15. otel-collector ──────────────────────────────────────────────────────
step "15/28  otel-collector"
is_done "15" || {
  helm_install otel-collector monitoring \
    "${CHARTS}/opentelemetry-collector" \
    -f "${VALUES}/otel-collector-values.yaml"
  mark_done "15"
}

# ─── 15b. OpenTelemetry Operator (Python auto-instrumentation via annotation) ─
step "15b/28  opentelemetry-operator"
is_done "15b" || {
  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
  helm repo update open-telemetry 2>/dev/null || true
  helm_install opentelemetry-operator monitoring \
    open-telemetry/opentelemetry-operator \
    -f "${VALUES}/otel-operator-values.yaml" \
    --timeout 5m
  success "OpenTelemetry Operator installed — pods with inject-python annotation will be auto-instrumented"
  mark_done "15b"
}

# ─── 16. kong ────────────────────────────────────────────────────────────────
step "16/28  kong"
is_done "16" || {
  helm_install kong kong \
    "${CHARTS}/kong" \
    -f "${VALUES}/kong-values.yaml"
  mark_done "16"
}

# ─── 16b. Kong IngressClass + ingress routes ─────────────────────────────────
step "16b/28  Kong IngressClass + service ingresses"
is_done "16b" || {
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
  kubectl apply -f "${INGRESS}/ingress-falco.yaml"

  success "IngressClass and all service ingresses applied"
  mark_done "16b"
}

# ─── 16c. ArgoCD AppProject + Applications ────────────────────────────────────
step "16c/28  ArgoCD AppProject + Applications"
is_done "16c" || {
  info "Applying ArgoCD AppProject ..."
  kubectl apply -f "${REPO_ROOT}/k8s/argocd/project.yaml"

  info "Applying ArgoCD Applications (microservices + locust) ..."
  kubectl apply -f "${REPO_ROOT}/k8s/argocd/microservices-app.yaml"
  kubectl apply -f "${REPO_ROOT}/k8s/argocd/locust-app.yaml"

  success "ArgoCD Applications registered — they will sync k8s/apps/ and k8s/load-generator/ automatically"
  mark_done "16c"
}

# Locust probe: removed from git manifest (k8s/load-generator/deployment.yaml)
# ArgoCD syncs the correct no-probe spec — no post-deploy patch needed

# ─── 17. falco ───────────────────────────────────────────────────────────────
step "17/28  falco"
is_done "17" || {
  helm_install falco falco \
    "${CHARTS}/falco" \
    -f "${VALUES}/falco-values.yaml"
  mark_done "17"
}

# ─── 18. sonarqube ───────────────────────────────────────────────────────────
step "18/28  sonarqube"
is_done "18" || {
  helm_install sonarqube sonarqube \
    "${CHARTS}/sonarqube" \
    -f "${VALUES}/sonarqube-values.yaml" \
    --timeout 10m
  mark_done "18"
}

# ─── 19. defectdojo ──────────────────────────────────────────────────────────
step "19/28  defectdojo"
is_done "19" || {
  # Wait for PostgreSQL to be fully accepting connections (not just Running)
  info "Waiting for PostgreSQL to accept connections (poll up to 3 min) ..."
  PG_READY=0
  for _i in $(seq 1 18); do
    if kubectl exec -n database postgresql-0 -- \
        env PGPASSWORD="$(kubectl get secret postgresql-credentials -n database -o jsonpath='{.data.postgres-password}' | base64 -d)" \
        psql -U postgres -c "SELECT 1;" &>/dev/null 2>&1; then
      PG_READY=1; break
    fi
    sleep 10
  done
  [ "${PG_READY}" -eq 1 ] || die "PostgreSQL not ready after 3 min — cannot install DefectDojo"
  success "PostgreSQL is ready"

  helm_install defectdojo defectdojo \
    "${CHARTS}/defectdojo" \
    -f "${VALUES}/defectdojo-values.yaml" \
    --timeout 15m
  mark_done "19"
}

# ─── 20. kyverno ─────────────────────────────────────────────────────────────
step "20/28  kyverno"
is_done "20" || {
  helm_install kyverno kyverno \
    "${CHARTS}/kyverno-3.8.1.tgz" \
    -f "${VALUES}/kyverno-values.yaml"

  info "Applying Kyverno policies ..."
  kubectl apply -f "${REPO_ROOT}/k8s/kyverno-policies/"
  success "Kyverno policies applied"
  mark_done "20"
}

# ─── 21. gatekeeper (OPA) ────────────────────────────────────────────────────
step "21/28  gatekeeper (OPA)"
is_done "21" || {
  helm_install gatekeeper gatekeeper-system \
    "${CHARTS}/gatekeeper-3.22.2.tgz" \
    -f "${VALUES}/gatekeeper-values.yaml"

  info "Waiting for Gatekeeper webhook to be ready (poll up to 3 min) ..."
  for _i in $(seq 1 18); do
    ready=$(kubectl get pods -n gatekeeper-system --no-headers 2>/dev/null \
      | grep -c "Running" || true)
    info "  [${_i}/18] Gatekeeper pods Running: ${ready}"
    [ "${ready}" -ge 2 ] && break
    sleep 10
  done

  info "Applying Gatekeeper ConstraintTemplates ..."
  kubectl apply -f "${REPO_ROOT}/k8s/gatekeeper/allowed-registries-template.yaml"
  kubectl apply -f "${REPO_ROOT}/k8s/gatekeeper/require-labels-template.yaml"

  info "Waiting for Gatekeeper CRDs to be established ..."
  for _i in $(seq 1 18); do
    ready=$(kubectl get crd 2>/dev/null \
      | grep -c "constrainttemplates\|allowedregistries\|requirelabels" || true)
    info "  [${_i}/18] Gatekeeper CRDs ready: ${ready}"
    [ "${ready}" -ge 1 ] && break
    sleep 10
  done

  info "Applying Gatekeeper Constraints (warn mode — violations logged, not blocked) ..."
  kubectl apply -f "${REPO_ROOT}/k8s/gatekeeper/allowed-registries-constraint.yaml"
  kubectl apply -f "${REPO_ROOT}/k8s/gatekeeper/require-labels-constraint.yaml"
  success "Gatekeeper constraints applied"
  mark_done "21"
}

# ─── 22. Prometheus Pushgateway (DORA metrics receiver) ──────────────────────
step "22/28  prometheus-pushgateway (DORA metrics)"
is_done "22" || {
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  helm repo update prometheus-community 2>/dev/null || true
  helm_install prometheus-pushgateway monitoring \
    prometheus-community/prometheus-pushgateway \
    -f "${VALUES}/pushgateway-values.yaml"
  success "Pushgateway installed — CI will push DORA metrics here after each deployment"
  info "Add secret PUSHGATEWAY_URL=http://prometheus-pushgateway.monitoring.svc.cluster.local:9091 to GitHub"
  mark_done "22"
}

# ─── 23. OpenCost (Kubernetes cost monitoring) ────────────────────────────────
step "23/28  opencost (FinOps)"
is_done "23" || {
  helm repo add opencost https://opencost.github.io/opencost-helm-chart 2>/dev/null || true
  helm repo update opencost 2>/dev/null || true
  helm_install opencost monitoring \
    opencost/opencost \
    -f "${VALUES}/opencost-values.yaml"
  success "OpenCost installed — cost metrics available in Grafana cost dashboard"
  mark_done "23"
}

# ─── 24. Application SLOs + Error Budget rules ────────────────────────────────
step "24/28  SLO recording rules + alerts"
is_done "24" || {
  kubectl apply -f "${REPO_ROOT}/k8s/slos/"
  success "PrometheusRule SLOs applied (order/payment/inventory — 99.9% availability SLO)"

  info "Applying ServiceMonitors for microservice metrics scraping ..."
  kubectl apply -f "${REPO_ROOT}/k8s/apps/servicemonitors.yaml"
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

# ─── 26. Backstage IDP ────────────────────────────────────────────────────────
step "26/28  Backstage IDP"
is_done "26" || {
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
  mark_done "26"
}

# ─── 27. LitmusChaos ─────────────────────────────────────────────────────────
step "27/28  LitmusChaos (chaos engineering)"
is_done "27" || {
  info "Adding litmuschaos helm repo ..."
  helm repo add litmuschaos https://litmuschaos.github.io/litmus-helm/ 2>/dev/null || true
  helm repo update litmuschaos 2>/dev/null || true

  # Create MongoDB credentials k8s secret from SM so nothing is hardcoded in values
  if ! kubectl get secret litmus-mongodb-secret -n litmus &>/dev/null; then
    info "Creating litmus-mongodb-secret from SM (intelliops/dev/litmus) ..."
    LITMUS_JSON=$(aws secretsmanager get-secret-value \
      --secret-id intelliops/dev/litmus --region "${REGION}" \
      --query SecretString --output text)
    LITMUS_MONGO_PASS=$(echo "${LITMUS_JSON}" | python3 -c \
      "import sys,json; print(json.load(sys.stdin)['mongodb_root_password'])")
    LITMUS_MONGO_USER=$(echo "${LITMUS_JSON}" | python3 -c \
      "import sys,json; print(json.load(sys.stdin)['mongodb_root_user'])")
    kubectl create secret generic litmus-mongodb-secret -n litmus \
      --from-literal=mongodb-root-password="${LITMUS_MONGO_PASS}" \
      --from-literal=mongodb-passwords="${LITMUS_MONGO_PASS}" \
      --from-literal=mongodb-replica-set-key="$(openssl rand -base64 32)" \
      --from-literal=mongodb-metrics-password="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20)"
    success "litmus-mongodb-secret created"
  else
    warn "litmus-mongodb-secret already exists — skipping"
  fi

  helm_install litmus litmus \
    litmuschaos/litmus \
    -f "${VALUES}/litmus-values.yaml" \
    --timeout 5m

  success "LitmusChaos installed — portal at http://localhost:9091 (port-forward: kubectl port-forward svc/litmus-frontend-service 9091:9091 -n litmus)"
  info "Chaos experiments: ${REPO_ROOT}/aiops/chaos/"
  info "Apply experiments ONLY when deliberately running chaos: kubectl apply -f aiops/chaos/<experiment>.yaml"
  mark_done "27"
}

# ─── 28. AIOps workloads (namespace + config + deployments) ──────────────────
step "28/28  AIOps workloads (anomaly-detector, forecaster, alert-correlator, ai-agent)"
is_done "28" || {
  info "Applying aiops-config ConfigMap + namespace resources ..."
  kubectl apply -f "${REPO_ROOT}/k8s/deployments/anomaly-detector.yaml"

  info "Patching aiops-config SQS_QUEUE_URL with account-specific queue URL ..."
  _ACCT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
  _REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
  if [ -n "${_ACCT}" ]; then
    _SQS_URL="https://sqs.${_REGION}.amazonaws.com/${_ACCT}/intelliops-anomalies"
    kubectl patch configmap aiops-config -n aiops-demo \
      --type merge \
      -p "{\"data\":{\"SQS_QUEUE_URL\":\"${_SQS_URL}\"}}" 2>/dev/null || true
    info "SQS URL set to: ${_SQS_URL}"
  else
    warn "Could not determine AWS account — SQS_QUEUE_URL left empty; ai-agent will poll but not send to SQS"
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
