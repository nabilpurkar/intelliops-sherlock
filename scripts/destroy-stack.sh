#!/usr/bin/env bash
# destroy-stack.sh — full teardown
#
# Sequence:
#   1.  Delete ArgoCD Applications (stop GitOps reconciliation first)
#   2.  Delete app workloads + all PVCs (prevents orphaned EBS volumes)
#   3.  Uninstall all Helm releases in dependency-safe order
#   4.  Wait for AWS Load Balancers to be deleted (prevents VPC destroy failure)
#   5.  Delete custom namespaces (force-remove stuck finalizers)
#   6.  Terraform destroy (EKS, VPC, IRSA, ECR, etc.)
#   7.  Delete Terraform state file + lock from S3
#   8.  STOP this EC2 instance (NOT terminate — instance is reusable)
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

# ── Error trap — tells you exactly which line failed ─────────────────────────
trap 'echo -e "\n${RED}[ERROR]${NC} Script exited unexpectedly at line ${LINENO}. Last command: ${BASH_COMMAND}" >&2' ERR

# ── Dynamic config ────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# aws configure get region exits 0 with empty string when not set — check explicitly
REGION=$(aws configure get region 2>/dev/null || true)
REGION=${REGION:-${AWS_DEFAULT_REGION:-us-east-1}}

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || die "Cannot resolve AWS account ID — check credentials"

TF_DIR="${REPO_ROOT}/terraform/environments/dev"
TF_BUCKET="intelliops-tfstate-cloudus"
TF_KEY="dev/terraform.tfstate"
TF_LOCK_KEY="${TF_KEY}.tflock"

# Cluster name — used to filter AWS resources created by K8s controllers
CLUSTER_NAME="intelliops-dev"

# Get this instance ID from IMDSv2
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)
if [ -n "${IMDS_TOKEN}" ]; then
  INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
    "http://169.254.169.254/latest/meta-data/instance-id" 2>/dev/null || true)
else
  INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text 2>/dev/null || true)
fi
[ -z "${INSTANCE_ID}" ] && die "Could not determine EC2 instance ID"

# Helm releases — reverse dependency order (dependents first)
# opencost + prometheus-pushgateway must come before kube-prometheus-stack
# aws-load-balancer-controller must be last (it manages AWS LBs)
HELM_RELEASES=(
  "gatekeeper:gatekeeper-system"
  "kyverno:kyverno"
  "litmus:litmus"
  "backstage:backstage"
  "defectdojo:defectdojo"
  "sonarqube:sonarqube"
  "falco:falco"
  "opencost:monitoring"
  "prometheus-pushgateway:monitoring"
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
  backstage litmus aiops-demo
)

# ── Confirmation ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${RED}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${RED}║           DESTROY STACK — FULL TEARDOWN             ║${NC}"
echo -e "${BOLD}${RED}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Account   : ${ACCOUNT_ID}"
echo -e "  Region    : ${REGION}"
echo -e "  Cluster   : ${CLUSTER_NAME}"
echo -e "  TF state  : s3://${TF_BUCKET}/${TF_KEY}"
echo -e "  Instance  : ${INSTANCE_ID} (will be STOPPED, not terminated)"
echo ""
echo -e "  ${RED}This will destroy the entire EKS cluster and ALL resources.${NC}"
echo -e "  ${RED}ECR repos + images ARE deleted (force_delete=true).${NC}"
echo -e "  ${RED}AWS SM secrets ARE deleted by terraform (regenerated on next install).${NC}"
echo ""

if [ "${SKIP_CONFIRM:-false}" != "true" ]; then
  read -r -p "  Type 'destroy' to confirm: " CONFIRM || true
  [ "${CONFIRM:-}" = "destroy" ] || { echo "Aborted."; exit 0; }
fi

echo ""

# ── Step 1: Stop ArgoCD auto-sync ─────────────────────────────────────────────
step "1/8  Pause ArgoCD Applications"

if kubectl get applications -n argocd &>/dev/null 2>&1; then
  for app in microservices locust; do
    kubectl patch application "${app}" -n argocd \
      --type merge -p '{"spec":{"syncPolicy":null}}' 2>/dev/null \
      && info "ArgoCD auto-sync disabled for ${app}" || true
  done
  kubectl delete application microservices locust -n argocd \
    --ignore-not-found --timeout=60s 2>/dev/null || true
  success "ArgoCD Applications removed"
else
  warn "ArgoCD not reachable — skipping (cluster may already be down)"
fi

# ── Step 2: Delete app workloads + ALL PVCs ────────────────────────────────────
# PVCs must be deleted explicitly BEFORE helm uninstall so the EBS CSI driver
# has a chance to delete the underlying EBS volumes. Skipping this leaves
# orphaned EBS volumes that block VPC/subnet destruction in terraform.
step "2/8  Delete app workloads and PVCs"

for ns in apps locust; do
  if kubectl get namespace "${ns}" &>/dev/null 2>&1; then
    info "Deleting all resources in namespace: ${ns} ..."
    kubectl delete all --all -n "${ns}" --timeout=60s 2>/dev/null || true
    kubectl delete ingress --all -n "${ns}" 2>/dev/null || true
    kubectl delete pvc --all -n "${ns}" --timeout=120s 2>/dev/null || true
    success "Namespace ${ns} cleared"
  fi
done

info "Deleting all PVCs cluster-wide (prevents orphaned EBS volumes) ..."
kubectl delete pvc --all -A --timeout=120s 2>/dev/null || true

# Delete all ingresses now — ExternalDNS needs time to clean Route53 before ALB is gone
info "Removing all ingresses (ExternalDNS will clean Route53 records) ..."
kubectl delete ingress --all -A --timeout=60s 2>/dev/null || true

info "Waiting 45s for ExternalDNS to remove Route53 records ..."
sleep 45

# ── Step 3: Uninstall Helm releases ───────────────────────────────────────────
step "3/8  Uninstall Helm releases"

for entry in "${HELM_RELEASES[@]}"; do
  release="${entry%%:*}"
  namespace="${entry##*:}"
  if helm status "${release}" -n "${namespace}" &>/dev/null 2>&1; then
    info "Uninstalling ${release} from ${namespace} ..."
    if helm uninstall "${release}" -n "${namespace}" --timeout 5m --wait 2>&1; then
      success "Uninstalled: ${release}"
    else
      warn "Failed to uninstall ${release} cleanly — forcing with no-hooks"
      helm uninstall "${release}" -n "${namespace}" --no-hooks 2>/dev/null || true
    fi
  else
    warn "${release} not installed — skipping"
  fi
done

# ── Step 4: Wait for AWS Load Balancers to be fully deleted ───────────────────
# This is the #1 cause of terraform destroy failures.
# The ALB/NLB controller deletes LBs asynchronously after helm uninstall.
# If terraform tries to delete subnets/VPC before LBs are gone, it fails.
step "4/8  Wait for AWS Load Balancers to be deleted"

info "Checking for ALBs/NLBs tagged with cluster ${CLUSTER_NAME} ..."
LB_WAIT=0
LB_MAX_WAIT=300  # 5 minutes max
while true; do
  LB_COUNT=$(aws elbv2 describe-load-balancers \
    --query "LoadBalancers[?contains(LoadBalancerName, '${CLUSTER_NAME}') || contains(to_string(Tags), '${CLUSTER_NAME}')].LoadBalancerArn" \
    --output text --region "${REGION}" 2>/dev/null | wc -w || echo "0")

  # Also check classic ELBs
  CLB_COUNT=$(aws elb describe-load-balancers \
    --query "LoadBalancerDescriptions[?contains(LoadBalancerName, 'k8s')].LoadBalancerName" \
    --output text --region "${REGION}" 2>/dev/null | wc -w || echo "0")

  TOTAL=$((LB_COUNT + CLB_COUNT))

  if [ "${TOTAL}" -eq 0 ]; then
    success "No AWS Load Balancers remaining"
    break
  fi

  if [ "${LB_WAIT}" -ge "${LB_MAX_WAIT}" ]; then
    warn "Timed out waiting for LBs to be deleted — attempting to delete manually"
    # Force-delete any remaining LBs tagged for this cluster
    aws elbv2 describe-load-balancers \
      --query "LoadBalancers[].LoadBalancerArn" \
      --output text --region "${REGION}" 2>/dev/null \
    | tr '\t' '\n' \
    | while read -r arn; do
        TAGS=$(aws elbv2 describe-tags --resource-arns "${arn}" \
          --query "TagDescriptions[0].Tags[?contains(Value,'${CLUSTER_NAME}')].Value" \
          --output text --region "${REGION}" 2>/dev/null || true)
        if [ -n "${TAGS}" ]; then
          warn "Force-deleting LB: ${arn}"
          aws elbv2 delete-load-balancer --load-balancer-arn "${arn}" \
            --region "${REGION}" 2>/dev/null || true
        fi
      done
    sleep 30
    break
  fi

  info "  ${TOTAL} load balancer(s) still deleting ... (${LB_WAIT}/${LB_MAX_WAIT}s)"
  sleep 15
  LB_WAIT=$((LB_WAIT + 15))
done

# Also clean up any leaked security groups created by the LB controller
info "Checking for leaked security groups ..."
aws ec2 describe-security-groups \
  --filters "Name=tag-key,Values=kubernetes.io/cluster/${CLUSTER_NAME}" \
  --query 'SecurityGroups[].GroupId' \
  --output text --region "${REGION}" 2>/dev/null \
| tr '\t' '\n' \
| while read -r sg; do
    [ -z "${sg}" ] && continue
    warn "Deleting leaked security group: ${sg}"
    aws ec2 delete-security-group --group-id "${sg}" \
      --region "${REGION}" 2>/dev/null || true
  done

success "AWS resource cleanup complete"

# ── Step 5: Delete custom namespaces ──────────────────────────────────────────
step "5/8  Delete namespaces"

# Remove ESO finalizers from ALL ExternalSecrets before deleting namespaces.
# When ESO is uninstalled first (step 3), its controller is gone and can no
# longer process finalizer-removal — causing namespaces to stick in Terminating.
info "Removing ExternalSecret finalizers to prevent stuck Terminating namespaces ..."
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  for es in $(kubectl get externalsecrets -n "${ns}" -o name 2>/dev/null); do
    kubectl patch "${es}" -n "${ns}" --type=json \
      -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
  done
done
success "ExternalSecret finalizers cleared"

for ns in "${CUSTOM_NAMESPACES[@]}"; do
  if kubectl get namespace "${ns}" &>/dev/null 2>&1; then
    info "Deleting namespace: ${ns} ..."
    kubectl delete namespace "${ns}" --timeout=90s 2>/dev/null \
      && success "Deleted: ${ns}" \
      || {
        warn "Namespace ${ns} stuck — forcing finalizer removal"
        # Clear spec.finalizers via the finalize sub-resource
        kubectl get namespace "${ns}" -o json 2>/dev/null \
          | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['spec']['finalizers'] = []
d['metadata'].pop('managedFields', None)
print(json.dumps(d))
" | kubectl replace --raw "/api/v1/namespaces/${ns}/finalize" -f - 2>/dev/null || true
      }
  fi
done

success "All namespaces cleaned"

# ── Step 6: Terraform destroy ─────────────────────────────────────────────────
step "6/8  Terraform destroy"

command -v terraform &>/dev/null || die "terraform not found in PATH"

[ -d "${TF_DIR}" ] || die "Terraform directory not found: ${TF_DIR}"
cd "${TF_DIR}"

# Always re-init — ensures backend is connected and providers are available.
# A stale or partial .terraform/ dir causes destroy to fail silently.
info "Initializing Terraform (reconfiguring backend) ..."
terraform init -reconfigure \
  || die "terraform init failed — check backend connectivity (S3: ${TF_BUCKET})"

info "Running terraform destroy (this takes ~15-20 minutes) ..."
terraform destroy -auto-approve -no-color \
  || {
    warn "terraform destroy exited non-zero — retrying once (common with eventual-consistency races) ..."
    sleep 30
    terraform destroy -auto-approve -no-color \
      || die "terraform destroy failed on retry — check output above and run manually"
  }

success "Terraform destroy complete"
cd "${REPO_ROOT}"

# ── Step 7: Delete S3 state file + lock ───────────────────────────────────────
step "7/8  Delete Terraform state from S3"

info "Deleting state file: s3://${TF_BUCKET}/${TF_KEY} ..."
aws s3 rm "s3://${TF_BUCKET}/${TF_KEY}" --region "${REGION}" \
  && success "State file deleted" \
  || warn "State file not found (may already be gone)"

info "Deleting lock file: s3://${TF_BUCKET}/${TF_LOCK_KEY} ..."
aws s3 rm "s3://${TF_BUCKET}/${TF_LOCK_KEY}" --region "${REGION}" 2>/dev/null \
  && success "Lock file deleted" \
  || warn "Lock file not found (no active lock)"

# Remove local terraform working directory (force clean init on next deploy)
rm -f "${TF_DIR}/tfplan" 2>/dev/null || true
rm -rf "${TF_DIR}/.terraform" 2>/dev/null || true
success "Local terraform state cleaned"

# ── Step 8: Stop this EC2 instance ────────────────────────────────────────────
step "8/8  Stopping EC2 instance"

echo ""
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Destroy complete!${NC}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${CYAN}EKS cluster${NC}    destroyed"
echo -e "  ${CYAN}Helm releases${NC}  uninstalled (${#HELM_RELEASES[@]} releases)"
echo -e "  ${CYAN}TF state${NC}       deleted from s3://${TF_BUCKET}/${TF_KEY}"
echo -e "  ${CYAN}AWS SM secrets${NC} deleted by terraform (regenerated on next install)"
echo -e "  ${CYAN}ECR repos${NC}      deleted (force_delete=true — rebuilt on next deploy)"
echo ""
echo -e "  ${YELLOW}To redeploy:${NC}"
echo -e "    Start this instance → SSH in → cd intelliops-sherlock"
echo -e "    GITHUB_PAT=ghp_xxx ./scripts/install-stack.sh"
echo ""
echo -e "  ${RED}Stopping instance ${INSTANCE_ID} in 10 seconds ...${NC}"
echo -e "  ${RED}(STOP only — instance is preserved, not terminated)${NC}"
echo ""

sleep 10

aws ec2 stop-instances \
  --instance-ids "${INSTANCE_ID}" \
  --region "${REGION}" \
  --output text \
  && echo "Stop command sent — instance is shutting down." \
  || die "Failed to stop instance ${INSTANCE_ID}"
