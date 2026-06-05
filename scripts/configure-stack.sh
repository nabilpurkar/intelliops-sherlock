#!/usr/bin/env bash
# configure-stack.sh — post-install app configuration
#
# Run after install-stack.sh to:
#   0. Bootstrap ECR images if empty (build+push locally)
#   1. Create SonarQube project + generate CI token
#   2. Get DefectDojo API token + create product
#   3. Collect ArgoCD / Grafana admin passwords + generate auth token
#   4. Store all tokens in AWS Secrets Manager
#   5. Re-apply ingresses so Kong reconciles addresses
#   6. Optionally push GitHub secrets (set GITHUB_PAT env var)
#   7. Write INSTRUCTIONS.md with all credentials and URLs
#
# Usage:
#   ./scripts/configure-stack.sh
#   GITHUB_PAT=ghp_xxx ./scripts/configure-stack.sh
#
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'

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

# ── Dynamic config — no hardcodes ─────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTRUCTIONS="${REPO_ROOT}/INSTRUCTIONS.md"

# AWS identity — resolved at runtime
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || die "Cannot resolve AWS account ID — check AWS credentials"

REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")

# EKS cluster name — try current kubeconfig context, fall back to searching
CLUSTER=$(kubectl config current-context 2>/dev/null \
  | sed 's|.*cluster/||; s|.*@||')
# If context is full ARN like "arn:aws:eks:...:cluster/intelliops-dev", strip to basename
CLUSTER=$(echo "${CLUSTER}" | sed 's|.*/||')
[ -z "${CLUSTER}" ] && CLUSTER=$(aws eks list-clusters --region "${REGION}" \
  --query 'clusters[0]' --output text 2>/dev/null)
[ -z "${CLUSTER}" ] && die "Cannot determine EKS cluster name"

# GitHub repo — parse from git remote
GITHUB_REPO=$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null \
  | sed 's|.*github.com[:/]||; s|\.git$||') \
  || GITHUB_REPO="unknown/repo"

# ECR registry prefix
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
ECR_NAMESPACE="intelliops-dev"

# Domain — derived from ExternalDNS wildcard ingress annotation if available, else config
DOMAIN=$(kubectl get ingress kong-gateway -n kong \
  -o jsonpath='{.spec.rules[0].host}' 2>/dev/null \
  | sed 's/^\*\.//' || echo "")
[ -z "${DOMAIN}" ] && DOMAIN="infrastructurepath.online"

ARGOCD_URL="https://argocd.${DOMAIN}"
GRAFANA_URL="https://grafana.${DOMAIN}"
PROMETHEUS_URL="https://prometheus.${DOMAIN}"
ALERTMANAGER_URL="https://alertmanager.${DOMAIN}"
SONAR_URL="https://sonarqube.${DOMAIN}"
DEFECTDOJO_URL="https://defectdojo.${DOMAIN}"
APPS_URL="https://apps.${DOMAIN}"
LOCUST_URL="https://locust.${DOMAIN}"
KONG_ADMIN_URL="https://kong-admin.${DOMAIN}"

SERVICES=(order-service payment-service inventory-service)
LOAD_GEN=load-generator

# ── Helpers ───────────────────────────────────────────────────────────────────

wait_for_url() {
  local name=$1 url=$2 max=${3:-60} delay=${4:-10}
  info "Waiting for ${name} to become ready ..."
  for i in $(seq 1 "${max}"); do
    local code
    code=$(curl -sk --max-time 5 -o /dev/null -w "%{http_code}" "${url}" 2>/dev/null || echo "000")
    # Accept any response except connection-refused (000) or gateway errors (502/503)
    if [ "${code}" != "000" ] && [ "${code}" != "502" ] && [ "${code}" != "503" ]; then
      success "${name} is ready (HTTP ${code})"
      return 0
    fi
    printf "    [%02d/%02d] not ready (HTTP %s) — sleeping %ds\n" "${i}" "${max}" "${code}" "${delay}"
    sleep "${delay}"
  done
  die "${name} did not respond after $((max * delay))s"
}

get_secret_key() {
  local secret_id=$1 key=$2
  aws secretsmanager get-secret-value \
    --secret-id "${secret_id}" --region "${REGION}" \
    --query SecretString --output text 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('${key}',''))" 2>/dev/null \
  || echo ""
}

upsert_secret_key() {
  local secret_id=$1 key=$2 value=$3
  local current_json
  current_json=$(aws secretsmanager get-secret-value \
    --secret-id "${secret_id}" --region "${REGION}" \
    --query SecretString --output text 2>/dev/null) || current_json="{}"

  local new_json
  new_json=$(python3 -c \
    "import sys,json; d=json.loads(sys.stdin.read()); d['${key}']='${value}'; print(json.dumps(d))" \
    <<< "${current_json}")

  if aws secretsmanager describe-secret --secret-id "${secret_id}" \
      --region "${REGION}" &>/dev/null; then
    aws secretsmanager put-secret-value \
      --secret-id "${secret_id}" --region "${REGION}" \
      --secret-string "${new_json}" >/dev/null
  else
    aws secretsmanager create-secret \
      --name "${secret_id}" --region "${REGION}" \
      --secret-string "${new_json}" >/dev/null
  fi
  success "AWS SM updated: ${secret_id} → ${key}"
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
step "Pre-flight checks"

command -v kubectl &>/dev/null || die "kubectl not found"
command -v aws     &>/dev/null || die "aws CLI not found"
command -v curl    &>/dev/null || die "curl not found"
command -v python3 &>/dev/null || die "python3 not found"
command -v docker  &>/dev/null || die "docker not found (needed for ECR bootstrap)"
command -v git     &>/dev/null || die "git not found"

kubectl cluster-info &>/dev/null \
  || die "kubectl cannot reach the cluster — run: aws eks update-kubeconfig --name ${CLUSTER} --region ${REGION}"

info "Cluster   : ${CLUSTER}"
info "Region    : ${REGION}"
info "Account   : ${ACCOUNT_ID}"
info "Domain    : ${DOMAIN}"
info "Registry  : ${REGISTRY}/${ECR_NAMESPACE}"
info "GitHub    : ${GITHUB_REPO}"

# ── ALB hostname ──────────────────────────────────────────────────────────────
step "ALB hostname"
ALB_HOST=$(kubectl get ingress kong-gateway -n kong \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")
info "ALB: ${ALB_HOST}"

# ─────────────────────────────────────────────────────────────────────────────
# 0. ECR image bootstrap — build + push if repositories are empty
#
# Source priority:
#   1. services/<svc>/  in this repo (full image from service repo clone)
#   2. Inline stub Dockerfile — minimal FastAPI stub so pods can start while
#      service CI pipelines push real images.  Stubs respond to /health, /ready,
#      /metrics, and all API routes with valid JSON so probes pass.
# ─────────────────────────────────────────────────────────────────────────────
step "0/7  ECR image bootstrap"

ecr_has_images() {
  local repo="${ECR_NAMESPACE}/$1"
  local count
  count=$(aws ecr list-images --region "${REGION}" \
    --repository-name "${repo}" \
    --query 'length(imageIds)' --output text 2>/dev/null || echo "0")
  [ "${count}" -gt 0 ]
}

# Port assignments match k8s/apps/*.yaml containerPort declarations
declare -A SVC_PORT=( [order-service]=8000 [payment-service]=8002 [inventory-service]=8001 )

# Build a minimal FastAPI stub image for a service, piping the Dockerfile inline.
# $1 = service name, $2 = port, $3 = full image ref
build_stub_image() {
  local svc=$1 port=$2 img=$3
  info "Building stub image for ${svc} (no services/${svc}/ found locally) ..."
  docker build -t "${img}" - <<DOCKERFILE
FROM python:3.12-slim
RUN pip install --no-cache-dir fastapi uvicorn prometheus-client 2>/dev/null
RUN useradd -u 1000 -m app
USER 1000
WORKDIR /app
RUN python3 -c "
import pathlib, textwrap
pathlib.Path('main.py').write_text(textwrap.dedent('''
  from fastapi import FastAPI
  from prometheus_client import generate_latest, CONTENT_TYPE_LATEST
  from starlette.responses import Response
  app = FastAPI(title=\"${svc} stub\")
  @app.get(\"/health\")
  def health(): return {\"status\": \"ok\", \"service\": \"${svc}\"}
  @app.get(\"/ready\")
  def ready():  return {\"status\": \"ready\"}
  @app.get(\"/metrics\")
  def metrics():
      return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
  @app.api_route(\"/{path:path}\", methods=[\"GET\",\"POST\",\"PUT\",\"DELETE\",\"PATCH\"])
  def catch_all(path: str): return {\"stub\": True, \"service\": \"${svc}\", \"path\": path}
'''))
"
EXPOSE ${port}
CMD ["python3", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "${port}"]
DOCKERFILE
}

need_bootstrap=false
for svc in "${SERVICES[@]}" "${LOAD_GEN}"; do
  if ! ecr_has_images "${svc}"; then
    need_bootstrap=true
    info "ECR ${ECR_NAMESPACE}/${svc} — no images found"
  else
    info "ECR ${ECR_NAMESPACE}/${svc} — images present, skipping build"
  fi
done

if ${need_bootstrap}; then
  info "Authenticating Docker with ECR ..."
  aws ecr get-login-password --region "${REGION}" \
    | docker login --username AWS --password-stdin "${REGISTRY}" \
    || die "Docker ECR login failed"

  for svc in "${SERVICES[@]}"; do
    img="${REGISTRY}/${ECR_NAMESPACE}/${svc}:latest"
    if ! ecr_has_images "${svc}"; then
      src_dir="${REPO_ROOT}/services/${svc}"
      if [ -d "${src_dir}" ]; then
        info "Building ${svc} from ${src_dir} ..."
        docker build -t "${img}" "${src_dir}" \
          || die "Docker build failed for ${svc}"
      else
        build_stub_image "${svc}" "${SVC_PORT[${svc}]}" "${img}" \
          || die "Stub build failed for ${svc}"
      fi
      info "Pushing ${svc} ..."
      docker push "${img}" || die "Docker push failed for ${svc}"
      success "${svc} image pushed to ECR"
    fi
  done

  # load-generator — use official locust image as stub if no local source
  load_img="${REGISTRY}/${ECR_NAMESPACE}/${LOAD_GEN}:latest"
  if ! ecr_has_images "${LOAD_GEN}"; then
    load_src="${REPO_ROOT}/services/${LOAD_GEN}"
    if [ -d "${load_src}" ]; then
      info "Building ${LOAD_GEN} from ${load_src} ..."
      docker build -t "${load_img}" "${load_src}" \
        || die "Docker build failed for ${LOAD_GEN}"
    else
      info "Building ${LOAD_GEN} stub (no services/${LOAD_GEN}/ found locally) ..."
      docker build -t "${load_img}" - <<'LOCUST_DOCKERFILE'
FROM locustio/locust:latest
USER root
RUN mkdir -p /mnt/locust
# Minimal locustfile so container starts without crashing
RUN printf 'from locust import HttpUser, task\nclass S(HttpUser):\n    @task\n    def t(self): self.client.get("/")\n' \
    > /mnt/locust/locustfile.py
USER locust
EXPOSE 8089
ENTRYPOINT ["locust", "-f", "/mnt/locust/locustfile.py", "--host=http://localhost"]
LOCUST_DOCKERFILE
    fi
    info "Pushing ${LOAD_GEN} ..."
    docker push "${load_img}" || die "Docker push failed for ${LOAD_GEN}"
    success "${LOAD_GEN} image pushed to ECR"
  fi

  info "Restarting deployments to pull fresh images ..."
  kubectl rollout restart deployment/order-service deployment/payment-service \
    deployment/inventory-service -n apps 2>/dev/null || true
  kubectl rollout restart deployment/locust -n locust 2>/dev/null || true
else
  success "All ECR images present — no bootstrap needed"
fi

# topology constraints fixed in git (ScheduleAnyway) + HPA maxReplicas=4 in manifests
# No patches needed here — ArgoCD syncs the correct values from git

# Wait for apps pods to be Running
info "Waiting for apps pods to be Running ..."
for attempt in $(seq 1 30); do
  not_running=$(kubectl get pods -n apps --no-headers 2>/dev/null \
    | grep -cvE '\s+(Running|Completed|Succeeded)\s+' || true)
  if [ "${not_running}" -eq 0 ]; then
    success "All apps pods Running"
    break
  fi
  printf "    [%02d/30] %d pod(s) not Running yet — waiting 10s\n" "${attempt}" "${not_running}"
  sleep 10
done

# ─────────────────────────────────────────────────────────────────────────────
# 0b. Ingress reconciliation — re-apply so Kong picks up running services
# ─────────────────────────────────────────────────────────────────────────────
step "0b/7  Ingress reconciliation"

INGRESS="${REPO_ROOT}/k8s/ingress"
info "Re-applying all ingresses to ensure Kong has current addresses ..."
kubectl apply -f "${INGRESS}/ingress-apps.yaml"        2>/dev/null || true
kubectl apply -f "${INGRESS}/ingress-kong-admin.yaml"  2>/dev/null || true
kubectl apply -f "${INGRESS}/ingress-locust.yaml"      2>/dev/null || true

# Give Kong 15s to reconcile
sleep 15

info "Ingress address summary:"
kubectl get ingress -A --no-headers \
  2>/dev/null | awk '{printf "  %-20s %-15s %s\n", $2, $5, $4}' || true

# ─────────────────────────────────────────────────────────────────────────────
# 1. SonarQube — create project + CI token
# ─────────────────────────────────────────────────────────────────────────────
step "1/7  SonarQube — project + CI token"

wait_for_url "SonarQube" "${SONAR_URL}/api/system/status" 60 10

SONAR_ADMIN="admin"
SONAR_ADMIN_PASS=$(get_secret_key "intelliops/dev/sonarqube" "admin_password")
[ -z "${SONAR_ADMIN_PASS}" ] && SONAR_ADMIN_PASS="admin"

if ! curl -sf --max-time 10 \
    -u "${SONAR_ADMIN}:${SONAR_ADMIN_PASS}" \
    "${SONAR_URL}/api/authentication/validate" \
  | python3 -c "import sys,json; assert json.load(sys.stdin).get('valid') is True" 2>/dev/null; then
  die "SonarQube admin credentials invalid.
  Store the correct password:
    aws secretsmanager put-secret-value \\
      --secret-id intelliops/dev/sonarqube \\
      --secret-string '{\"admin_password\":\"<password>\"}'"
fi
info "SonarQube credentials validated"

HTTP=$(curl -so /dev/null -w "%{http_code}" \
  -u "${SONAR_ADMIN}:${SONAR_ADMIN_PASS}" \
  -X POST "${SONAR_URL}/api/projects/create" \
  --data-urlencode "name=IntelliOps Sherlock" \
  -d "project=intelliops-sherlock&visibility=private" 2>/dev/null)
case "${HTTP}" in
  200|201) success "SonarQube project 'intelliops-sherlock' created" ;;
  400)     warn    "SonarQube project already exists — skipping" ;;
  *)       die     "Failed to create SonarQube project (HTTP ${HTTP})" ;;
esac

curl -sf -u "${SONAR_ADMIN}:${SONAR_ADMIN_PASS}" \
  -X POST "${SONAR_URL}/api/user_tokens/revoke" \
  -d "name=github-ci" >/dev/null 2>&1 || true

SONAR_TOKEN=$(curl -sf \
  -u "${SONAR_ADMIN}:${SONAR_ADMIN_PASS}" \
  -X POST "${SONAR_URL}/api/user_tokens/generate" \
  -d "name=github-ci&type=USER_TOKEN" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
success "SonarQube CI token generated"

upsert_secret_key "intelliops/dev/sonarqube" "admin_password" "${SONAR_ADMIN_PASS}"
upsert_secret_key "intelliops/dev/sonarqube" "ci_token"       "${SONAR_TOKEN}"

# ─────────────────────────────────────────────────────────────────────────────
# 2. DefectDojo — API token + product
# ─────────────────────────────────────────────────────────────────────────────
step "2/7  DefectDojo — API token + product"

wait_for_url "DefectDojo API" "${DEFECTDOJO_URL}/api/v2/users/?limit=1" 60 10

DD_ADMIN="admin"

# Priority: k8s secret (set by Helm) → AWS SM → fail
DD_ADMIN_PASS=$(kubectl get secret defectdojo -n defectdojo \
  -o jsonpath='{.data.DD_ADMIN_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

if [ -z "${DD_ADMIN_PASS}" ]; then
  DD_ADMIN_PASS=$(get_secret_key "intelliops/dev/defectdojo" "admin_password")
fi

[ -z "${DD_ADMIN_PASS}" ] \
  && die "DefectDojo admin password not found in k8s secret or AWS SM"

DD_TOKEN=$(curl -sf -X POST "${DEFECTDOJO_URL}/api/v2/api-token-auth/" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"${DD_ADMIN}\",\"password\":\"${DD_ADMIN_PASS}\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
success "DefectDojo API token retrieved"

HTTP=$(curl -so /dev/null -w "%{http_code}" \
  -X POST "${DEFECTDOJO_URL}/api/v2/products/" \
  -H "Authorization: Token ${DD_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"name":"IntelliOps Sherlock","description":"AIOps security demo platform","prod_type":1}' 2>/dev/null)
case "${HTTP}" in
  200|201) success "DefectDojo product 'IntelliOps Sherlock' created" ;;
  400)     warn    "DefectDojo product already exists — skipping" ;;
  *)       warn    "DefectDojo product create returned HTTP ${HTTP} — continuing" ;;
esac

# Store both password and token so next run doesn't need the k8s secret
upsert_secret_key "intelliops/dev/defectdojo" "admin_password" "${DD_ADMIN_PASS}"
upsert_secret_key "intelliops/dev/defectdojo" "api_key"        "${DD_TOKEN}"

kubectl annotate externalsecret falco-defectdojo-secret -n falco \
  "force-sync=$(date +%s)" --overwrite >/dev/null 2>&1 \
  && info "Triggered ExternalSecret refresh for falco-defectdojo-apikey" || true

# ─────────────────────────────────────────────────────────────────────────────
# 3. ArgoCD — admin password + Applications + auth token
# ─────────────────────────────────────────────────────────────────────────────
step "3/7  ArgoCD — credentials + Applications + auth token"

# Priority: k8s initial-admin-secret → AWS SM
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "")

if [ -z "${ARGOCD_PASS}" ]; then
  ARGOCD_PASS=$(get_secret_key "intelliops/dev/argocd" "admin_password")
fi

if [ -z "${ARGOCD_PASS}" ]; then
  warn "Could not retrieve ArgoCD password — skipping Application apply and token generation"
  ARGOCD_AUTH_TOKEN=""
else
  success "ArgoCD admin password retrieved"
  upsert_secret_key "intelliops/dev/argocd" "admin_password" "${ARGOCD_PASS}"

  info "Applying ArgoCD AppProject and Applications ..."
  kubectl apply -f "${REPO_ROOT}/k8s/argocd/project.yaml"
  kubectl apply -f "${REPO_ROOT}/k8s/argocd/microservices-app.yaml"
  kubectl apply -f "${REPO_ROOT}/k8s/argocd/locust-app.yaml"
  kubectl apply -f "${REPO_ROOT}/k8s/argocd/aiops-app.yaml"
  success "ArgoCD Applications registered (microservices + locust + aiops)"

  wait_for_url "ArgoCD API" "${ARGOCD_URL}/api/v1/session" 30 10

  ARGOCD_AUTH_TOKEN=$(curl -sf -X POST "${ARGOCD_URL}/api/v1/session" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"admin\",\"password\":\"${ARGOCD_PASS}\"}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])") || ARGOCD_AUTH_TOKEN=""

  if [ -n "${ARGOCD_AUTH_TOKEN}" ]; then
    upsert_secret_key "intelliops/dev/argocd" "auth_token" "${ARGOCD_AUTH_TOKEN}"
    success "ArgoCD auth token generated and stored in AWS SM"
  else
    warn "Could not generate ArgoCD auth token — CI will rely on auto-sync"
    ARGOCD_AUTH_TOKEN=""
  fi

  # Trigger sync for both apps
  for app in microservices locust; do
    curl -sf -X POST "${ARGOCD_URL}/api/v1/applications/${app}/sync" \
      -H "Authorization: Bearer ${ARGOCD_AUTH_TOKEN}" \
      -H "Content-Type: application/json" \
      -d '{"prune":true}' >/dev/null 2>&1 \
      && success "${app} sync triggered" \
      || warn "${app} sync trigger failed (will auto-sync in ~3 min)"
  done
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. Grafana — admin password
# ─────────────────────────────────────────────────────────────────────────────
step "4/7  Grafana — admin password"

# Priority: k8s secret → AWS SM
GRAFANA_PASS=$(kubectl get secret kube-prometheus-stack-grafana -n monitoring \
  -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

if [ -z "${GRAFANA_PASS}" ]; then
  GRAFANA_PASS=$(get_secret_key "intelliops/dev/grafana" "admin_password")
fi
[ -z "${GRAFANA_PASS}" ] && GRAFANA_PASS="(check AWS SM: intelliops/dev/grafana → admin_password)"

if [ "${GRAFANA_PASS}" != "(check AWS SM: intelliops/dev/grafana → admin_password)" ]; then
  upsert_secret_key "intelliops/dev/grafana" "admin_password" "${GRAFANA_PASS}"
  success "Grafana admin password retrieved and synced to AWS SM"
else
  warn "Grafana password not found in k8s secret or AWS SM"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. Kong admin password
# ─────────────────────────────────────────────────────────────────────────────
step "5/7  Kong admin credentials"

KONG_ADMIN_PASS=$(kubectl get secret kong-enterprise-superuser-password -n kong \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

if [ -z "${KONG_ADMIN_PASS}" ]; then
  KONG_ADMIN_PASS=$(get_secret_key "intelliops/dev/kong" "admin_password")
fi
[ -z "${KONG_ADMIN_PASS}" ] && KONG_ADMIN_PASS="(see AWS SM: intelliops/dev/kong)"

success "Kong admin credentials retrieved"

# ─────────────────────────────────────────────────────────────────────────────
# 6. GitHub secrets (optional — only when GITHUB_PAT is set)
# ─────────────────────────────────────────────────────────────────────────────
step "6/7  GitHub secrets"

if [ -n "${GITHUB_PAT:-}" ]; then
  info "GITHUB_PAT detected — pushing secrets to ${GITHUB_REPO} ..."

  python3 - <<PYTHON
import json, base64, urllib.request, sys, subprocess

try:
    from nacl import encoding, public
except ImportError:
    subprocess.check_call([sys.executable, "-m", "pip", "install", "PyNaCl", "--quiet"])
    from nacl import encoding, public

def gh_request(token, method, path, data=None):
    url = f"https://api.github.com{path}"
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(url, data=body, method=method, headers={
        "Authorization": f"token {token}",
        "Accept": "application/vnd.github+json",
        "Content-Type": "application/json",
    })
    with urllib.request.urlopen(req) as r:
        raw = r.read()
        return json.loads(raw) if raw else {}

def encrypt_secret(pub_key_b64, value):
    pk = public.PublicKey(pub_key_b64.encode(), encoding.Base64Encoder())
    return base64.b64encode(public.SealedBox(pk).encrypt(value.encode())).decode()

token = "${GITHUB_PAT}"
repo  = "${GITHUB_REPO}"

key_data = gh_request(token, "GET", f"/repos/{repo}/actions/secrets/public-key")
key_id   = key_data["key_id"]
pub_key  = key_data["key"]

secrets = {
    "SONAR_TOKEN":        "${SONAR_TOKEN}",
    "DEFECTDOJO_API_KEY": "${DD_TOKEN}",
    "ARGOCD_AUTH_TOKEN":  "${ARGOCD_AUTH_TOKEN:-}",
}
secrets = {k: v for k, v in secrets.items() if v}

for name, value in secrets.items():
    gh_request(token, "PUT", f"/repos/{repo}/actions/secrets/{name}", {
        "encrypted_value": encrypt_secret(pub_key, value),
        "key_id": key_id,
    })
    print(f"  [OK] {name} set")

print("  GitHub secrets updated successfully")
PYTHON

  success "GitHub secrets pushed: SONAR_TOKEN + DEFECTDOJO_API_KEY + ARGOCD_AUTH_TOKEN"
else
  warn "GITHUB_PAT not set — copy values from INSTRUCTIONS.md to GitHub manually"
  info "  Re-run with: GITHUB_PAT=ghp_xxx ./scripts/configure-stack.sh"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 7. Write INSTRUCTIONS.md
# ─────────────────────────────────────────────────────────────────────────────
step "7/7  Writing INSTRUCTIONS.md"

TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

cat > "${INSTRUCTIONS}" <<EOF
# IntelliOps Sherlock — Complete Operations Reference

> Last updated by \`scripts/configure-stack.sh\` on ${TIMESTAMP}
> Gitignored — regenerated on every cluster deploy. Never commit this file.

---

## Quick Links

| Tool | URL | Username | Password |
|------|-----|----------|----------|
| **GitHub Actions (CI)** | https://github.com/${GITHUB_REPO}/actions | — | — |
| **ArgoCD** | ${ARGOCD_URL} | \`admin\` | \`${ARGOCD_PASS}\` |
| **SonarQube** | ${SONAR_URL} | \`admin\` | \`${SONAR_ADMIN_PASS}\` |
| **DefectDojo** | ${DEFECTDOJO_URL} | \`admin\` | \`${DD_ADMIN_PASS}\` |
| **Grafana** | ${GRAFANA_URL} | \`admin\` | \`${GRAFANA_PASS}\` |
| **Prometheus** | ${PROMETHEUS_URL} | — | — |
| **Alertmanager** | ${ALERTMANAGER_URL} | — | — |
| **Apps (microservices)** | ${APPS_URL} | — | — |
| **Locust** | ${LOCUST_URL} | — | — |
| **Kong Admin API** | ${KONG_ADMIN_URL} | — | — |
| **Falco UI** | port-forward only (see §13) | — | — |

---

## 1. Pre-Commit Hooks

**Config file:** \`.pre-commit-config.yaml\`

Install locally:
\`\`\`bash
pip install pre-commit
pre-commit install          # hooks run on every git commit
pre-commit run --all-files  # run manually against all files
\`\`\`

| Hook | What it checks | Change config in |
|------|---------------|------------------|
| \`trailing-whitespace\` | Removes trailing spaces | \`.pre-commit-config.yaml\` |
| \`end-of-file-fixer\` | Ensures newline at EOF | \`.pre-commit-config.yaml\` |
| \`check-yaml\` | YAML syntax validation | \`.pre-commit-config.yaml\` |
| \`check-json\` | JSON syntax validation | \`.pre-commit-config.yaml\` |
| \`detect-private-key\` | Blocks accidental key commits | \`.pre-commit-config.yaml\` |
| \`gitleaks\` | Secret scanning (tokens, passwords) | \`.gitleaks.toml\` |
| \`terraform_fmt\` | Terraform formatting | \`.pre-commit-config.yaml\` |
| \`terraform_validate\` | Terraform syntax validation | \`.pre-commit-config.yaml\` |
| \`checkov\` | Terraform IaC misconfigurations | \`.pre-commit-config.yaml\` |

**Gitleaks allowlist:** \`.gitleaks.toml\` — vendor helm charts excluded from scanning.

---

## 2. GitHub Actions Pipeline

**URL:** https://github.com/${GITHUB_REPO}/actions
**Pipeline file:** \`.github/workflows/ci.yml\`

\`\`\`
detect-changes → gitleaks → sast → unit-tests → sca → sonarqube
  → iac-scan → build-push → update-manifests → argocd-sync → dast
\`\`\`

| Stage | Workflow file | Runs when |
|-------|--------------|-----------|
| detect-changes | \`ci.yml\` | always |
| gitleaks | \`_gitleaks.yml\` | always |
| sast (Semgrep) | \`_sast.yml\` | always |
| unit-tests | \`_unit-tests.yml\` | service files changed |
| sca (Trivy+OWASP) | \`_sca.yml\` | always |
| sonarqube | \`_sonarqube.yml\` | always |
| iac-scan (Checkov) | \`_iac-scan.yml\` | terraform files changed |
| build-push | \`_docker-build-push.yml\` | main + service changes |
| update-manifests | \`_update-manifests.yml\` | main + service changes |
| argocd-sync | \`_argocd-sync.yml\` | main + service changes |
| dast (ZAP) | \`_dast-scan.yml\` | main + service changes |

### GitHub Secrets

| Secret | Value | Used by |
|--------|-------|---------|
| \`SONAR_TOKEN\` | \`${SONAR_TOKEN}\` | \`_sonarqube.yml\` |
| \`DEFECTDOJO_API_KEY\` | \`${DD_TOKEN}\` | all scan workflows |
| \`ARGOCD_AUTH_TOKEN\` | *(24-hr JWT — refresh via configure-stack.sh)* | \`_argocd-sync.yml\` |

---

## 3. Gitleaks — Secret Scanning

**Workflow:** \`.github/workflows/_gitleaks.yml\`
**Config:** \`.gitleaks.toml\` — vendor helm charts excluded
**Scope:** full git history (\`fetch-depth: 0\`)

Reports → GitHub Actions → \`gitleaks\` job logs
Failures block all downstream stages.

\`\`\`bash
# Run locally
pre-commit run gitleaks --all-files
\`\`\`

---

## 4. Semgrep — SAST

**Workflow:** \`.github/workflows/_sast.yml\`
**Rules:** \`p/python\`, \`p/secrets\`, \`p/owasp-top-ten\`
**Target:** \`services/\`

Reports:
- GitHub Code Scanning: https://github.com/${GITHUB_REPO}/security/code-scanning
- DefectDojo: ${DEFECTDOJO_URL} → Products → IntelliOps Sherlock → \`CI Pipeline - SAST\`

\`\`\`bash
# Run locally
docker run --rm -v "\$(pwd):/src" returntocorp/semgrep \\
  semgrep scan --config=p/python --config=p/owasp-top-ten /src/services
\`\`\`

---

## 5. Unit Tests

**Workflow:** \`.github/workflows/_unit-tests.yml\`
**Runs when:** any file under \`services/\` changes
**Framework:** pytest + FastAPI TestClient

| Service | Test file | Run locally |
|---------|-----------|-------------|
| order-service | \`services/order-service/tests/test_main.py\` | \`cd services/order-service && pytest tests/ -v\` |
| payment-service | \`services/payment-service/tests/test_main.py\` | \`cd services/payment-service && pytest tests/ -v\` |
| inventory-service | \`services/inventory-service/tests/test_main.py\` | \`cd services/inventory-service && pytest tests/ -v\` |

Config per service: \`services/<service>/pytest.ini\`
Test deps: \`services/<service>/requirements-test.txt\`

CI report → GitHub Actions → \`unit-tests\` job logs
Failure blocks SCA, SonarQube, and all downstream stages.

---

## 6. Dependency Scan (SCA)

**Workflow:** \`.github/workflows/_sca.yml\`

### Trivy Filesystem
**Output:** \`trivy-fs.sarif\`
**Severity:** CRITICAL, HIGH
- GitHub Code Scanning: https://github.com/${GITHUB_REPO}/security/code-scanning (filter: \`trivy-fs\`)
- DefectDojo: \`CI Pipeline - Trivy FS\`

### OWASP Dependency-Check
**Output:** \`dependency-check-report.sarif\`, \`dependency-check-report.xml\`
**Fails at:** CVSS ≥ 9
- GitHub Code Scanning: https://github.com/${GITHUB_REPO}/security/code-scanning (filter: \`dependency-check\`)
- DefectDojo: \`CI Pipeline - OWASP Dep-Check\`

\`\`\`bash
# Run Trivy locally
docker run --rm -v "\$(pwd):/repo" aquasec/trivy:latest fs /repo/services --severity CRITICAL,HIGH
\`\`\`

---

## 7. SonarQube — Code Quality Gate

**URL:** ${SONAR_URL}
**Username:** \`admin\` | **Password:** \`${SONAR_ADMIN_PASS}\`
**Project key:** \`intelliops-sherlock\`
**CI Token:** \`${SONAR_TOKEN}\`
**Config file:** \`sonar-project.properties\`
**Workflow:** \`.github/workflows/_sonarqube.yml\`

| Page | URL |
|------|-----|
| Project dashboard | ${SONAR_URL}/dashboard?id=intelliops-sherlock |
| Quality gate | ${SONAR_URL}/project/quality_gate?id=intelliops-sherlock |
| Issues | ${SONAR_URL}/project/issues?id=intelliops-sherlock |
| Scan history | ${SONAR_URL}/project/activity?id=intelliops-sherlock |
| Security hotspots | ${SONAR_URL}/security_hotspots?id=intelliops-sherlock |

DefectDojo: \`CI Pipeline - SonarQube\` engagement
Quality gate failure blocks build-push and all downstream stages.

---

## 8. IaC Scan — Checkov

**Workflow:** \`.github/workflows/_iac-scan.yml\`
**Target:** \`terraform/\` | **Mode:** soft_fail (reports, does not block)
**Runs when:** terraform files changed

- GitHub Code Scanning: https://github.com/${GITHUB_REPO}/security/code-scanning (filter: \`checkov\`)
- DefectDojo: \`CI Pipeline - Checkov IaC\`

\`\`\`bash
cd terraform/environments/dev && checkov -d . --framework terraform
\`\`\`

---

## 9. Docker Build → Trivy Image Scan → Cosign Sign → ECR Push

**Workflow:** \`.github/workflows/_docker-build-push.yml\`
**Runs:** main branch only, service files changed

### ECR Repositories

| Service | ECR URI |
|---------|---------|
| order-service | \`${REGISTRY}/${ECR_NAMESPACE}/order-service\` |
| payment-service | \`${REGISTRY}/${ECR_NAMESPACE}/payment-service\` |
| inventory-service | \`${REGISTRY}/${ECR_NAMESPACE}/inventory-service\` |
| load-generator | \`${REGISTRY}/${ECR_NAMESPACE}/load-generator\` |

Tags: \`<git-sha>\` (pinned) + \`latest\`
AWS Console: https://us-east-1.console.aws.amazon.com/ecr/repositories?region=${REGION}

### Trivy Image Scan
Output: \`trivy-image.sarif\` | Severity: CRITICAL,HIGH | exit-code: 1 (blocks push)
- GitHub Code Scanning: https://github.com/${GITHUB_REPO}/security/code-scanning (filter: \`trivy-image-*\`)
- DefectDojo: \`CI Pipeline - Trivy Image (<service>)\`

### Cosign — Keyless Signing (GitHub OIDC)
\`\`\`bash
# Verify a signed image
cosign verify \\
  ${REGISTRY}/${ECR_NAMESPACE}/order-service:<sha> \\
  --certificate-identity-regexp="https://github.com/${GITHUB_REPO}" \\
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com"
\`\`\`

\`\`\`bash
# Pull an image locally
aws ecr get-login-password --region ${REGION} \\
  | docker login --username AWS --password-stdin ${REGISTRY}
docker pull ${REGISTRY}/${ECR_NAMESPACE}/order-service:latest
\`\`\`

---

## 10. DAST — OWASP ZAP

**Workflow:** \`.github/workflows/_dast-scan.yml\`
**Target:** ${APPS_URL}
**Type:** Baseline (passive) | Runs after ArgoCD deploy is Healthy

- GitHub Issues: https://github.com/${GITHUB_REPO}/issues (auto-created per alert)
- GitHub Code Scanning: https://github.com/${GITHUB_REPO}/security/code-scanning
- DefectDojo: \`CI Pipeline - DAST ZAP\`

\`\`\`bash
# Run locally
docker run -t ghcr.io/zaproxy/zaproxy:stable zap-baseline.py -t ${APPS_URL}
\`\`\`

---

## 11. K8s Admission Policies

### Kyverno (Audit mode — violations reported, not blocked)
Namespace targeted: \`apps\`

| Policy file | Enforcement |
|-------------|------------|
| \`k8s/kyverno-policies/disallow-privileged.yaml\` | No privileged containers |
| \`k8s/kyverno-policies/disallow-latest-tag.yaml\` | No :latest image tags |
| \`k8s/kyverno-policies/require-resource-limits.yaml\` | CPU + memory limits required |
| \`k8s/kyverno-policies/restrict-image-registries.yaml\` | Images only from ECR |

\`\`\`bash
kubectl get policyreport -n apps
kubectl describe policyreport -n apps
\`\`\`

### OPA Gatekeeper (Warn mode — violations logged, not blocked)

| File | Enforcement |
|------|------------|
| \`k8s/gatekeeper/allowed-registries-template.yaml\` | ConstraintTemplate |
| \`k8s/gatekeeper/allowed-registries-constraint.yaml\` | ECR-only images in apps |
| \`k8s/gatekeeper/require-labels-template.yaml\` | ConstraintTemplate |
| \`k8s/gatekeeper/require-labels-constraint.yaml\` | \`app\` + \`team\` labels required |

\`\`\`bash
kubectl get constraint
kubectl get validatingwebhookconfigurations | grep -E "kyverno|gatekeeper"
\`\`\`

---

## 12. Deploy — ArgoCD

**URL:** ${ARGOCD_URL}
**Username:** \`admin\` | **Password:** \`${ARGOCD_PASS}\`
**AWS SM:** \`intelliops/dev/argocd\` → \`admin_password\`

| App | Watches | Namespace | Link |
|-----|---------|-----------|------|
| \`microservices\` | \`k8s/apps/\` | \`apps\` | ${ARGOCD_URL}/applications/microservices |
| \`locust\` | \`k8s/load-generator/\` | \`locust\` | ${ARGOCD_URL}/applications/locust |

Manifest files:
\`\`\`
k8s/apps/_bootstrap.yaml          ServiceAccount + ConfigMap
k8s/apps/order-service.yaml       Deployment + Service + HPA
k8s/apps/payment-service.yaml     Deployment + Service + HPA
k8s/apps/inventory-service.yaml   Deployment + Service + HPA
k8s/load-generator/deployment.yaml Deployment + Service
k8s/argocd/project.yaml           AppProject
k8s/argocd/microservices-app.yaml
k8s/argocd/locust-app.yaml
\`\`\`

GitOps flow: push → CI bumps tag in \`k8s/apps/{service}.yaml\` → ArgoCD detects → syncs to EKS

\`\`\`bash
kubectl get applications -n argocd
kubectl annotate application microservices -n argocd argocd.argoproj.io/refresh=hard --overwrite
\`\`\`

---

## 13. Falco — Runtime Security

**Namespace:** \`falco\` | **Mode:** eBPF DaemonSet (one pod per node)

**FalcoSidekick UI** (no ingress — use port-forward):
\`\`\`bash
kubectl port-forward svc/falco-falcosidekick-ui 2802:2802 -n falco
# Open: http://localhost:2802
\`\`\`

Alerts → DefectDojo: ${DEFECTDOJO_URL} → \`Falco Runtime\` engagement
Config: \`k8s/helm-values/falco-values.yaml\`

\`\`\`bash
# Live alert stream
kubectl logs -n falco -l app.kubernetes.io/name=falco -c falco --tail=50 -f

# Sidekick routing logs
kubectl logs -n falco -l app.kubernetes.io/name=falcosidekick --tail=30
\`\`\`

---

## 14. Prometheus & Grafana

| | URL | Creds |
|--|-----|-------|
| Grafana | ${GRAFANA_URL} | \`admin\` / \`${GRAFANA_PASS}\` |
| Prometheus | ${PROMETHEUS_URL} | none |
| Alertmanager | ${ALERTMANAGER_URL} | none |

**AWS SM:** \`intelliops/dev/grafana\` → \`admin_password\`
**Config:** \`k8s/helm-values/kube-prometheus-values.yaml\`

Key Grafana dashboards:
- Kubernetes / Compute Resources / Namespace → filter to \`apps\`
- Node Exporter / Nodes
- Loki → Explore → \`{namespace="apps"}\`

Useful PromQL:
\`\`\`promql
rate(http_requests_total{namespace="apps"}[5m])
container_memory_working_set_bytes{namespace="apps"}
\`\`\`

---

## 15. DefectDojo — Vulnerability Hub

**URL:** ${DEFECTDOJO_URL}
**Username:** \`admin\` | **Password:** \`${DD_ADMIN_PASS}\`
**API Token:** \`${DD_TOKEN}\`
**AWS SM:** \`intelliops/dev/defectdojo\` → \`admin_password\`, \`api_key\`

| Engagement | Populated by |
|------------|-------------|
| \`CI Pipeline - SAST\` | Semgrep |
| \`CI Pipeline - Trivy FS\` | Trivy filesystem |
| \`CI Pipeline - OWASP Dep-Check\` | OWASP Dep-Check |
| \`CI Pipeline - SonarQube\` | SonarQube export |
| \`CI Pipeline - Checkov IaC\` | Checkov |
| \`CI Pipeline - Trivy Image (<svc>)\` | Trivy image scan |
| \`CI Pipeline - DAST ZAP\` | OWASP ZAP |
| \`Falco Runtime\` | Falco alerts |

\`\`\`bash
# API — list active findings
curl -H "Authorization: Token ${DD_TOKEN}" \\
  ${DEFECTDOJO_URL}/api/v2/findings/?active=true | python3 -m json.tool
\`\`\`

---

## 16. Cluster & Infrastructure

**Cluster:** \`${CLUSTER}\` | **Region:** \`${REGION}\` | **Account:** \`${ACCOUNT_ID}\`
**ALB:** \`${ALB_HOST}\`
**Wildcard DNS:** \`*.${DOMAIN}\` → ALB (ExternalDNS managed)

AWS SM secrets:
| Path | Keys |
|------|------|
| \`intelliops/dev/postgresql\` | \`pg_password\`, \`sonarqube_password\`, \`defectdojo_password\` |
| \`intelliops/dev/sonarqube\` | \`admin_password\`, \`ci_token\` |
| \`intelliops/dev/defectdojo\` | \`admin_password\`, \`api_key\`, \`secret_key\`, \`valkey_password\` |
| \`intelliops/dev/argocd\` | \`admin_password\`, \`auth_token\` |
| \`intelliops/dev/grafana\` | \`admin_password\` |
| \`intelliops/dev/linkerd\` | \`issuer_crt\`, \`issuer_key\` |

\`\`\`bash
# Kubeconfig
aws eks update-kubeconfig --name ${CLUSTER} --region ${REGION}

# Unhealthy pods
kubectl get pods -A --no-headers | grep -vE 'Running|Completed|Succeeded'

# All ingresses
kubectl get ingress -A

# HPA status
kubectl get hpa -n apps

# ExternalSecret sync
kubectl get externalsecret -A

# Helm releases
helm list -A
\`\`\`

---

## 17. Reinstallation Playbook

\`\`\`bash
# 1. Terraform
cd terraform/environments/dev && terraform apply tfplan

# 2. Full stack (configure-stack.sh runs automatically at end)
GITHUB_PAT=ghp_xxx ./scripts/install-stack.sh

# 3. Refresh ARGOCD_AUTH_TOKEN only
GITHUB_PAT=ghp_xxx ./scripts/configure-stack.sh
\`\`\`

What configure-stack.sh does: builds ECR images if empty → waits for pods → fixes ingresses →
SonarQube project+token → DefectDojo product+token → ArgoCD auth token → Grafana password →
pushes GitHub secrets → writes this file.

---

*Gitignored — never commit. Re-run after every cluster recreate.*
EOF

success "INSTRUCTIONS.md written → ${INSTRUCTIONS}"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
_TOTAL=$(( $(date +%s) - START_TIME ))
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Configuration complete! — total time: $(( _TOTAL / 60 ))m$(( _TOTAL % 60 ))s${NC}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${CYAN}Apps${NC}        ${APPS_URL}"
echo -e "  ${CYAN}SonarQube${NC}   ${SONAR_URL}"
echo -e "  ${CYAN}DefectDojo${NC}  ${DEFECTDOJO_URL}"
echo -e "  ${CYAN}ArgoCD${NC}      ${ARGOCD_URL}"
echo -e "  ${CYAN}Grafana${NC}     ${GRAFANA_URL}"
echo -e "  ${CYAN}Locust${NC}      ${LOCUST_URL}"
echo ""
info "INSTRUCTIONS.md → ${INSTRUCTIONS}"
info "AWS SM updated: intelliops/dev/{sonarqube,defectdojo,argocd,grafana}"
if [ -n "${GITHUB_PAT:-}" ]; then
  success "GitHub secrets pushed automatically"
else
  warn "GitHub secrets — copy from INSTRUCTIONS.md or re-run with GITHUB_PAT=ghp_xxx"
fi
echo ""
