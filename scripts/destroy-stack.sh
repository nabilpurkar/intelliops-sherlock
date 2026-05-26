#!/usr/bin/env bash
# destroy-stack.sh — full teardown
#
# Sequence:
#   1.  Delete ArgoCD Applications (stop GitOps reconciliation first)
#   2.  Delete app workloads from k8s (apps, locust namespaces)
#   3.  Uninstall all Helm releases in dependency-safe order
#   4.  Delete custom namespaces
#   5.  Terraform destroy (EKS, VPC, IRSA, ECR, etc.)
#   6.  Delete Terraform state file + lock from S3
#   7.  STOP this EC2 instance (NOT terminate — instance is reusable)
#
# Usage:
#   ./scripts/destroy-stack.sh
#   SKIP_CONFIRM=true ./scripts/destroy-stack.sh   # non-interactive (CI)
#
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step()    { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${NC}";
            echo -e "${BOLD}${CYAN}  $*${NC}";
            echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Dynamic config ────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || die "Cannot resolve AWS account ID — check credentials"

TF_DIR="${REPO_ROOT}/terraform/environments/dev"
TF_BUCKET="intelliops-tfstate-cloudus"
TF_KEY="dev/terraform.tfstate"
TF_LOCK_KEY="${TF_KEY}.tflock"

# Get this instance ID from IMDSv2
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || echo "")
if [ -n "${IMDS_TOKEN}" ]; then
  INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
    "http://169.254.169.254/latest/meta-data/instance-id" 2>/dev/null || echo "")
else
  INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text 2>/dev/null || echo "")
fi
[ -z "${INSTANCE_ID}" ] && die "Could not determine EC2 instance ID"

# Helm releases in reverse dependency order (dependents first)
HELM_RELEASES=(
  "gatekeeper:gatekeeper-system"
  "kyverno:kyverno"
  "defectdojo:defectdojo"
  "sonarqube:sonarqube"
  "falco:falco"
  "loki:monitoring"
  "tempo:monitoring"
  "otel-collector:monitoring"
  "kube-prometheus-stack:monitoring"
  "kong:kong"
  "argocd:argocd"
  "linkerd-control-plane:linkerd"
  "linkerd-crds:linkerd"
  "external-dns:external-dns"
  "postgresql:database"
  "cluster-autoscaler:kube-system"
  "metrics-server:kube-system"
  "aws-load-balancer-controller:kube-system"
  "external-secrets:external-secrets"
  "cert-manager:cert-manager"
)

# Custom namespaces to delete after helm uninstall
CUSTOM_NAMESPACES=(
  apps locust argocd defectdojo sonarqube falco kong
  monitoring external-dns external-secrets cert-manager
  database linkerd gatekeeper-system kyverno
)

# ── Confirmation ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${RED}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${RED}║           DESTROY STACK — FULL TEARDOWN             ║${NC}"
echo -e "${BOLD}${RED}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Account   : ${ACCOUNT_ID}"
echo -e "  Region    : ${REGION}"
echo -e "  TF state  : s3://${TF_BUCKET}/${TF_KEY}"
echo -e "  Instance  : ${INSTANCE_ID} (will be STOPPED, not terminated)"
echo ""
echo -e "  ${RED}This will destroy the entire EKS cluster and all resources.${NC}"
echo -e "  ${RED}ECR images are NOT deleted (reusable on next deploy).${NC}"
echo -e "  ${YELLOW}AWS SM secrets are NOT deleted (credentials survive).${NC}"
echo ""

if [ "${SKIP_CONFIRM:-false}" != "true" ]; then
  read -r -p "  Type 'destroy' to confirm: " CONFIRM
  [ "${CONFIRM}" = "destroy" ] || { echo "Aborted."; exit 0; }
fi

echo ""

# ── Step 1: Stop ArgoCD auto-sync (prevents reconciliation fighting teardown) ──
step "1/7  Pause ArgoCD Applications"

if kubectl get applications -n argocd &>/dev/null; then
  for app in microservices locust; do
    kubectl patch application "${app}" -n argocd \
      --type merge -p '{"spec":{"syncPolicy":null}}' 2>/dev/null \
      && info "ArgoCD auto-sync disabled for ${app}" || true
  done
  kubectl delete application microservices locust -n argocd \
    --ignore-not-found --timeout=30s 2>/dev/null || true
  success "ArgoCD Applications removed"
else
  warn "ArgoCD not reachable — skipping"
fi

# ── Step 2: Delete app workloads ───────────────────────────────────────────────
step "2/7  Delete app workloads"

for ns in apps locust; do
  if kubectl get namespace "${ns}" &>/dev/null; then
    info "Deleting all resources in namespace: ${ns} ..."
    kubectl delete all --all -n "${ns}" --timeout=60s 2>/dev/null || true
    kubectl delete ingress --all -n "${ns}" 2>/dev/null || true
    kubectl delete pvc --all -n "${ns}" 2>/dev/null || true
    success "Namespace ${ns} cleared"
  fi
done

# Remove ingresses so external-dns cleans up DNS records before ALB is gone
info "Removing all ingresses (lets ExternalDNS clean DNS before ALB gone) ..."
kubectl delete ingress --all -A --timeout=60s 2>/dev/null || true
info "Waiting 20s for ExternalDNS to remove Route53 records ..."
sleep 20

# ── Step 3: Uninstall Helm releases ───────────────────────────────────────────
step "3/7  Uninstall Helm releases"

for entry in "${HELM_RELEASES[@]}"; do
  release="${entry%%:*}"
  namespace="${entry##*:}"
  if helm status "${release}" -n "${namespace}" &>/dev/null; then
    info "Uninstalling ${release} from ${namespace} ..."
    helm uninstall "${release}" -n "${namespace}" --timeout 5m --wait 2>/dev/null \
      && success "Uninstalled: ${release}" \
      || warn "Failed to uninstall ${release} cleanly — continuing"
  else
    warn "${release} not installed — skipping"
  fi
done

# ── Step 4: Delete custom namespaces ──────────────────────────────────────────
step "4/7  Delete namespaces"

for ns in "${CUSTOM_NAMESPACES[@]}"; do
  if kubectl get namespace "${ns}" &>/dev/null; then
    info "Deleting namespace: ${ns} ..."
    kubectl delete namespace "${ns}" --timeout=90s 2>/dev/null \
      && success "Deleted: ${ns}" \
      || warn "Namespace ${ns} stuck — forcing finalizer removal"
    # Force-remove stuck namespaces (common with CRDs)
    kubectl get namespace "${ns}" -o json 2>/dev/null \
      | python3 -c "
import sys,json
d=json.load(sys.stdin)
d['spec']['finalizers']=[]
print(json.dumps(d))
" | kubectl replace --raw "/api/v1/namespaces/${ns}/finalize" -f - 2>/dev/null || true
  fi
done

success "All namespaces cleaned"

# ── Step 5: Terraform destroy ─────────────────────────────────────────────────
step "5/7  Terraform destroy"

command -v terraform &>/dev/null || die "terraform not found in PATH"

cd "${TF_DIR}"

if [ ! -f ".terraform/terraform.tfstate" ] && [ ! -d ".terraform" ]; then
  info "Terraform not initialized — running init first ..."
  terraform init -reconfigure 2>/dev/null || die "terraform init failed"
fi

info "Running terraform destroy (this takes ~15-20 minutes) ..."
terraform destroy -auto-approve \
  || die "terraform destroy failed — check output above and retry"

success "Terraform destroy complete"
cd "${REPO_ROOT}"

# ── Step 6: Delete S3 state file + lock ───────────────────────────────────────
step "6/7  Delete Terraform state from S3"

info "Deleting state file: s3://${TF_BUCKET}/${TF_KEY} ..."
aws s3 rm "s3://${TF_BUCKET}/${TF_KEY}" --region "${REGION}" 2>/dev/null \
  && success "State file deleted" \
  || warn "State file not found (may already be gone)"

info "Deleting lock file: s3://${TF_BUCKET}/${TF_LOCK_KEY} ..."
aws s3 rm "s3://${TF_BUCKET}/${TF_LOCK_KEY}" --region "${REGION}" 2>/dev/null \
  && success "Lock file deleted" \
  || warn "Lock file not found (no active lock)"

# Also remove any local terraform state/plan files
rm -f "${TF_DIR}/tfplan" "${TF_DIR}/.terraform.lock.hcl" 2>/dev/null || true
rm -rf "${TF_DIR}/.terraform" 2>/dev/null || true
success "Local terraform state cleaned"

# ── Step 7: Stop this EC2 instance ────────────────────────────────────────────
step "7/7  Stopping EC2 instance"

echo ""
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Destroy complete!${NC}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${CYAN}EKS cluster${NC}    destroyed"
echo -e "  ${CYAN}Helm releases${NC}  uninstalled (${#HELM_RELEASES[@]} releases)"
echo -e "  ${CYAN}TF state${NC}       deleted from s3://${TF_BUCKET}/${TF_KEY}"
echo -e "  ${CYAN}AWS SM secrets${NC} preserved (use on next deploy)"
echo -e "  ${CYAN}ECR images${NC}     preserved (faster next bootstrap)"
echo ""
echo -e "  ${YELLOW}To redeploy:${NC}"
echo -e "    Start this instance → SSH in → cd intelliops-sherlock"
echo -e "    cd terraform/environments/dev && terraform init && terraform apply"
echo -e "    GITHUB_PAT=ghp_xxx ./scripts/install-stack.sh"
echo ""
echo -e "  ${RED}Stopping instance ${INSTANCE_ID} in 10 seconds ...${NC}"
echo -e "  ${RED}(STOP only — instance is preserved, not terminated)${NC}"
echo ""

# Give a moment to read the output, then stop
sleep 10

aws ec2 stop-instances \
  --instance-ids "${INSTANCE_ID}" \
  --region "${REGION}" \
  --output text \
  && echo "Stop command sent — instance is shutting down." \
  || die "Failed to stop instance ${INSTANCE_ID}"
