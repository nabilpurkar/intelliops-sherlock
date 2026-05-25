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

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[SKIP]${NC}  $*"; }
step()    { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${NC}";
            echo -e "${BOLD}${CYAN}  $*${NC}";
            echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

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
    src_dir="${REPO_ROOT}/services/${svc}"
    img="${REGISTRY}/${ECR_NAMESPACE}/${svc}:latest"
    if ! ecr_has_images "${svc}"; then
      info "Building ${svc} ..."
      docker build -t "${img}" "${src_dir}" \
        || die "Docker build failed for ${svc}"
      info "Pushing ${svc} ..."
      docker push "${img}" \
        || die "Docker push failed for ${svc}"
      success "${svc} image pushed to ECR"
    fi
  done

  # load-generator
  load_src="${REPO_ROOT}/services/${LOAD_GEN}"
  load_img="${REGISTRY}/${ECR_NAMESPACE}/${LOAD_GEN}:latest"
  if ! ecr_has_images "${LOAD_GEN}"; then
    info "Building ${LOAD_GEN} ..."
    docker build -t "${load_img}" "${load_src}" \
      || die "Docker build failed for ${LOAD_GEN}"
    info "Pushing ${LOAD_GEN} ..."
    docker push "${load_img}" \
      || die "Docker push failed for ${LOAD_GEN}"
    success "${LOAD_GEN} image pushed to ECR"
  fi

  info "Restarting deployments to pull fresh images ..."
  kubectl rollout restart deployment/order-service deployment/payment-service \
    deployment/inventory-service -n apps 2>/dev/null || true
  kubectl rollout restart deployment/locust -n locust 2>/dev/null || true
else
  success "All ECR images present — no bootstrap needed"
fi

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
  success "ArgoCD Applications registered"

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
# IntelliOps Sherlock — Stack Access Instructions

> **Auto-generated** by \`scripts/configure-stack.sh\` on ${TIMESTAMP}
> This file is gitignored — recreated on every cluster deploy.

---

## Cluster

| Key | Value |
|-----|-------|
| Cluster name | \`${CLUSTER}\` |
| AWS Region | \`${REGION}\` |
| Account ID | \`${ACCOUNT_ID}\` |
| ALB hostname | \`${ALB_HOST}\` |
| Wildcard DNS | \`*.${DOMAIN}\` → ALB above |
| ECR Registry | \`${REGISTRY}/${ECR_NAMESPACE}\` |
| GitHub Repo | \`${GITHUB_REPO}\` |

---

## Service URLs & Credentials

### ArgoCD (GitOps)
| | |
|---|---|
| URL | ${ARGOCD_URL} |
| Username | \`admin\` |
| Password | \`${ARGOCD_PASS}\` |

### Grafana (Dashboards)
| | |
|---|---|
| URL | ${GRAFANA_URL} |
| Username | \`admin\` |
| Password | \`${GRAFANA_PASS}\` |

### Prometheus
| | |
|---|---|
| URL | ${PROMETHEUS_URL} |

### Alertmanager
| | |
|---|---|
| URL | ${ALERTMANAGER_URL} |

### SonarQube (SAST / Quality Gate)
| | |
|---|---|
| URL | ${SONAR_URL} |
| Username | \`admin\` |
| Password | \`${SONAR_ADMIN_PASS}\` |
| CI Token | \`${SONAR_TOKEN}\` |
| Project key | \`intelliops-sherlock\` |

### DefectDojo (Vulnerability Management)
| | |
|---|---|
| URL | ${DEFECTDOJO_URL} |
| Username | \`admin\` |
| Password | \`${DD_ADMIN_PASS}\` |
| API Token | \`${DD_TOKEN}\` |

### Apps (microservices)
| | |
|---|---|
| URL | ${APPS_URL} |
| Endpoints | \`/orders\` \`/payments\` \`/inventory\` \`/health\` \`/metrics\` |

### Locust (Load generator)
| | |
|---|---|
| URL | ${LOCUST_URL} |

### Kong Admin API
| | |
|---|---|
| URL | ${KONG_ADMIN_URL} |

---

## GitHub Repository Secrets

Set these in **GitHub → repo → Settings → Secrets → Actions**:

\`\`\`
SONAR_TOKEN        = ${SONAR_TOKEN}
DEFECTDOJO_API_KEY = ${DD_TOKEN}
ARGOCD_AUTH_TOKEN  = ${ARGOCD_AUTH_TOKEN:-<not generated>}
\`\`\`

> **ARGOCD_AUTH_TOKEN** is a 24-hour JWT. Re-run \`configure-stack.sh\` to refresh.
> Without it the pipeline still works — ArgoCD auto-syncs within ~3 minutes.

To push all secrets automatically (needs PAT with \`repo\` scope):
\`\`\`bash
GITHUB_PAT=ghp_xxx ./scripts/configure-stack.sh
\`\`\`

---

## AWS Secrets Manager Reference

| Path | Keys stored |
|------|-------------|
| \`intelliops/dev/postgresql\` | \`pg_password\`, \`sonarqube_password\`, \`defectdojo_password\` |
| \`intelliops/dev/sonarqube\` | \`admin_password\`, \`ci_token\` |
| \`intelliops/dev/defectdojo\` | \`admin_password\`, \`api_key\`, \`secret_key\`, \`valkey_password\` |
| \`intelliops/dev/argocd\` | \`admin_password\`, \`auth_token\` |
| \`intelliops/dev/grafana\` | \`admin_password\` |
| \`intelliops/dev/kong\` | *(kong credentials)* |
| \`intelliops/dev/linkerd\` | \`issuer_crt\`, \`issuer_key\` |

---

## Useful Commands

\`\`\`bash
# Kubeconfig
aws eks update-kubeconfig --name ${CLUSTER} --region ${REGION}

# All non-healthy pods
kubectl get pods -A --no-headers | grep -vE 'Running|Completed|Succeeded'

# ArgoCD app status
kubectl get applications -n argocd

# Check ExternalSecret sync
kubectl get externalsecret -A

# Manually refresh a secret
kubectl annotate externalsecret <name> -n <namespace> force-sync=\$(date +%s) --overwrite

# ArgoCD password (from k8s)
kubectl -n argocd get secret argocd-initial-admin-secret \\
  -o jsonpath="{.data.password}" | base64 -d && echo

# Helm releases
helm list -A

# ALB hostname
kubectl get ingress kong-gateway -n kong \\
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
\`\`\`

---

## Reinstallation Playbook

\`\`\`bash
# 1. Terraform — provision EKS + networking + IRSA
cd terraform/environments/dev
terraform plan -out tfplan
terraform apply tfplan

# 2. Helm stack + auto-configure (configure-stack.sh runs automatically at end)
GITHUB_PAT=ghp_xxx ./scripts/install-stack.sh

# Or run configure step separately:
GITHUB_PAT=ghp_xxx ./scripts/configure-stack.sh
\`\`\`

---

*Gitignored — re-run \`configure-stack.sh\` after every cluster recreate.*
EOF

success "INSTRUCTIONS.md written → ${INSTRUCTIONS}"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Configuration complete!${NC}"
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
