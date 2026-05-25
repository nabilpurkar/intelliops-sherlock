#!/usr/bin/env bash
# configure-stack.sh — post-install app configuration
#
# Run after install-stack.sh to:
#   1. Create SonarQube project + generate CI token
#   2. Get DefectDojo API token + create product
#   3. Collect ArgoCD / Grafana admin passwords
#   4. Store tokens in AWS Secrets Manager
#   5. Optionally push GitHub secrets (set GITHUB_PAT env var)
#   6. Write INSTRUCTIONS.md with all credentials and URLs
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

# ── Config ────────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTRUCTIONS="${REPO_ROOT}/INSTRUCTIONS.md"

DOMAIN="infrastructurepath.online"
CLUSTER="intelliops-dev"
REGION="us-east-1"
ACCOUNT_ID="007066145518"
GITHUB_REPO="nabilpurkar/intelliops-sherlock"

ARGOCD_URL="https://argocd.${DOMAIN}"
GRAFANA_URL="https://grafana.${DOMAIN}"
PROMETHEUS_URL="https://prometheus.${DOMAIN}"
ALERTMANAGER_URL="https://alertmanager.${DOMAIN}"
SONAR_URL="https://sonarqube.${DOMAIN}"
DEFECTDOJO_URL="https://defectdojo.${DOMAIN}"
APPS_URL="https://apps.${DOMAIN}"
LOCUST_URL="https://locust.${DOMAIN}"
KONG_ADMIN_URL="https://kong-admin.${DOMAIN}"

# ── Helpers ───────────────────────────────────────────────────────────────────

# Poll a URL until it responds 2xx, then return.
wait_for_url() {
  local name=$1 url=$2 max=${3:-60} delay=${4:-10}
  info "Waiting for ${name} to become ready ..."
  for i in $(seq 1 "${max}"); do
    if curl -sfk --max-time 5 "${url}" >/dev/null 2>&1; then
      success "${name} is ready"
      return 0
    fi
    printf "    [%02d/%02d] not ready yet — sleeping %ds\n" "${i}" "${max}" "${delay}"
    sleep "${delay}"
  done
  die "${name} did not respond after $((max * delay))s — is the service healthy?"
}

# Read a single key from an AWS Secrets Manager JSON secret.
get_secret_key() {
  local secret_id=$1 key=$2
  aws secretsmanager get-secret-value \
    --secret-id "${secret_id}" --region "${REGION}" \
    --query SecretString --output text 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('${key}',''))"
}

# Add/update one key inside an existing AWS SM secret (or create the secret).
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

command -v kubectl &>/dev/null || die "kubectl not found in PATH"
command -v aws     &>/dev/null || die "aws CLI not found in PATH"
command -v curl    &>/dev/null || die "curl not found in PATH"
command -v python3 &>/dev/null || die "python3 not found in PATH"
kubectl cluster-info &>/dev/null \
  || die "kubectl cannot reach the cluster — run: aws eks update-kubeconfig --name ${CLUSTER} --region ${REGION}"

info "All pre-flight checks passed"

# ── ALB hostname ──────────────────────────────────────────────────────────────
step "ALB hostname"
ALB_HOST=$(kubectl get ingress kong-gateway -n kong \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")
info "ALB: ${ALB_HOST}"

# ─────────────────────────────────────────────────────────────────────────────
# 1. SonarQube — create project + CI token
# ─────────────────────────────────────────────────────────────────────────────
step "1/4  SonarQube — project + CI token"

wait_for_url "SonarQube" "${SONAR_URL}/api/system/status" 60 10

SONAR_ADMIN="admin"
# Fresh install default is admin/admin; subsequent runs use value stored in SM.
SONAR_ADMIN_PASS=$(get_secret_key "intelliops/dev/sonarqube" "admin_password" 2>/dev/null || true)
[ -z "${SONAR_ADMIN_PASS}" ] && SONAR_ADMIN_PASS="admin"

# Validate credentials
if ! curl -sf --max-time 10 \
    -u "${SONAR_ADMIN}:${SONAR_ADMIN_PASS}" \
    "${SONAR_URL}/api/authentication/validate" \
  | python3 -c "import sys,json; assert json.load(sys.stdin).get('valid') is True" 2>/dev/null; then
  die "SonarQube admin credentials invalid.
  If you changed the password manually, store it:
    aws secretsmanager put-secret-value \\
      --secret-id intelliops/dev/sonarqube \\
      --secret-string '{\"admin_password\":\"<your-password>\"}'"
fi
info "SonarQube credentials validated"

# Create project — 400 means already exists, that's fine.
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

# Revoke existing CI token (idempotent — ignore if not found)
curl -sf -u "${SONAR_ADMIN}:${SONAR_ADMIN_PASS}" \
  -X POST "${SONAR_URL}/api/user_tokens/revoke" \
  -d "name=github-ci" >/dev/null 2>&1 || true

# Generate fresh token
SONAR_TOKEN=$(curl -sf \
  -u "${SONAR_ADMIN}:${SONAR_ADMIN_PASS}" \
  -X POST "${SONAR_URL}/api/user_tokens/generate" \
  -d "name=github-ci&type=USER_TOKEN" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
success "SonarQube CI token generated"

# Store admin password + token in SM so next cluster recreate picks them up
upsert_secret_key "intelliops/dev/sonarqube" "admin_password" "${SONAR_ADMIN_PASS}"
upsert_secret_key "intelliops/dev/sonarqube" "ci_token"       "${SONAR_TOKEN}"

# ─────────────────────────────────────────────────────────────────────────────
# 2. DefectDojo — API token + product
# ─────────────────────────────────────────────────────────────────────────────
step "2/4  DefectDojo — API token + product"

wait_for_url "DefectDojo API" "${DEFECTDOJO_URL}/api/v2/users/?limit=1" 60 10

DD_ADMIN="admin"
DD_ADMIN_PASS=$(get_secret_key "intelliops/dev/defectdojo" "admin_password")
[ -z "${DD_ADMIN_PASS}" ] \
  && die "DefectDojo admin_password not found in intelliops/dev/defectdojo — check AWS SM"

# Get API token via token-auth endpoint
DD_TOKEN=$(curl -sf -X POST "${DEFECTDOJO_URL}/api/v2/api-token-auth/" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"${DD_ADMIN}\",\"password\":\"${DD_ADMIN_PASS}\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
success "DefectDojo API token retrieved"

# Create product — 400 means already exists
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

# Store token in SM + trigger falcosidekick secret refresh
upsert_secret_key "intelliops/dev/defectdojo" "api_key" "${DD_TOKEN}"

kubectl annotate externalsecret falco-defectdojo-secret -n falco \
  "force-sync=$(date +%s)" --overwrite >/dev/null 2>&1 \
  && info "Triggered ExternalSecret refresh for falco-defectdojo-apikey" || true

# ─────────────────────────────────────────────────────────────────────────────
# 3. ArgoCD — admin password
# ─────────────────────────────────────────────────────────────────────────────
step "3/4  ArgoCD — admin password"

ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || true)

if [ -z "${ARGOCD_PASS}" ]; then
  ARGOCD_PASS=$(get_secret_key "intelliops/dev/argocd" "admin_password" 2>/dev/null || true)
fi

if [ -z "${ARGOCD_PASS}" ]; then
  ARGOCD_PASS="run: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
  warn "Could not retrieve ArgoCD password automatically"
else
  success "ArgoCD admin password retrieved"
  # Store for future cluster recreates
  upsert_secret_key "intelliops/dev/argocd" "admin_password" "${ARGOCD_PASS}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. Grafana — admin password
# ─────────────────────────────────────────────────────────────────────────────
step "4/4  Grafana — admin password"

GRAFANA_PASS=$(get_secret_key "intelliops/dev/grafana" "admin_password" 2>/dev/null || true)
[ -z "${GRAFANA_PASS}" ] && GRAFANA_PASS="(check AWS SM: intelliops/dev/grafana → admin_password)"
success "Grafana admin password retrieved"

# ─────────────────────────────────────────────────────────────────────────────
# GitHub secrets (optional — only when GITHUB_PAT is set)
# ─────────────────────────────────────────────────────────────────────────────
step "GitHub secrets"

if [ -n "${GITHUB_PAT:-}" ]; then
  info "GITHUB_PAT detected — pushing secrets to ${GITHUB_REPO} ..."

  python3 - <<PYTHON
import json, base64, urllib.request, sys, subprocess

# Install PyNaCl if missing (needed for GitHub secret encryption)
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
        return json.load(r) if r.read(1) else {}

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
}

for name, value in secrets.items():
    gh_request(token, "PUT", f"/repos/{repo}/actions/secrets/{name}", {
        "encrypted_value": encrypt_secret(pub_key, value),
        "key_id": key_id,
    })
    print(f"  ✓ {name} set")

print("  GitHub secrets updated successfully")
PYTHON

  success "GitHub secrets SONAR_TOKEN + DEFECTDOJO_API_KEY updated"
else
  warn "GITHUB_PAT not set — copy values from INSTRUCTIONS.md to GitHub manually"
  info "  Re-run with: GITHUB_PAT=ghp_xxx ./scripts/configure-stack.sh"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Write INSTRUCTIONS.md
# ─────────────────────────────────────────────────────────────────────────────
step "Writing INSTRUCTIONS.md"

TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

cat > "${INSTRUCTIONS}" <<EOF
# IntelliOps Sherlock — Stack Access Instructions

> **Auto-generated** by \`scripts/configure-stack.sh\` on ${TIMESTAMP}
> This file is gitignored — it is recreated on every cluster deploy.

---

## Cluster

| Key | Value |
|-----|-------|
| Cluster name | \`${CLUSTER}\` |
| AWS Region | \`${REGION}\` |
| Account ID | \`${ACCOUNT_ID}\` |
| ALB hostname | \`${ALB_HOST}\` |
| Wildcard DNS | \`*.${DOMAIN}\` → ALB above |

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
| Auth | None (internal) |

### Alertmanager
| | |
|---|---|
| URL | ${ALERTMANAGER_URL} |
| Auth | None (internal) |

### SonarQube (SAST / Quality Gate)
| | |
|---|---|
| URL | ${SONAR_URL} |
| Username | \`admin\` |
| Password | \`${SONAR_ADMIN_PASS}\` |
| Project key | \`intelliops-sherlock\` |
| CI token name | \`github-ci\` |

### DefectDojo (Vulnerability Management)
| | |
|---|---|
| URL | ${DEFECTDOJO_URL} |
| Username | \`admin\` |
| Password | \`${DD_ADMIN_PASS}\` |

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

Set these in **GitHub → repo → Settings → Secrets and variables → Actions**:

\`\`\`
SONAR_TOKEN        = ${SONAR_TOKEN}
DEFECTDOJO_API_KEY = ${DD_TOKEN}
\`\`\`

To update them automatically next time (needs a PAT with \`repo\` scope):
\`\`\`bash
GITHUB_PAT=ghp_xxx ./scripts/configure-stack.sh
\`\`\`

---

## AWS Secrets Manager Reference

All credentials survive cluster destroy/recreate via these paths:

| Path | Relevant keys |
|------|---------------|
| \`intelliops/dev/postgresql\` | \`pg_password\`, \`sonarqube_password\`, \`defectdojo_password\` |
| \`intelliops/dev/sonarqube\` | \`admin_password\`, \`ci_token\` |
| \`intelliops/dev/defectdojo\` | \`admin_password\`, \`api_key\`, \`secret_key\`, \`valkey_password\` |
| \`intelliops/dev/argocd\` | \`admin_password\` |
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

# Check ExternalSecret sync status
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

# 2. Helm stack — install all 22 components
./scripts/install-stack.sh

# 3. Configure apps — create projects, tokens, write this file
GITHUB_PAT=ghp_xxx ./scripts/configure-stack.sh
\`\`\`

---

*This file is gitignored (\`.gitignore\` has \`INSTRUCTIONS.md\`).
Re-run \`configure-stack.sh\` after every cluster recreate.*
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
echo -e "  ${CYAN}SonarQube${NC}   ${SONAR_URL}"
echo -e "  ${CYAN}DefectDojo${NC}  ${DEFECTDOJO_URL}"
echo -e "  ${CYAN}ArgoCD${NC}      ${ARGOCD_URL}"
echo -e "  ${CYAN}Grafana${NC}     ${GRAFANA_URL}"
echo ""
info "INSTRUCTIONS.md → ${INSTRUCTIONS}"
info "AWS SM updated: intelliops/dev/sonarqube, intelliops/dev/defectdojo, intelliops/dev/argocd"
if [ -n "${GITHUB_PAT:-}" ]; then
  success "GitHub secrets SONAR_TOKEN + DEFECTDOJO_API_KEY pushed automatically"
else
  warn "GitHub secrets not set — copy from INSTRUCTIONS.md or re-run with GITHUB_PAT=ghp_xxx"
fi
echo ""
