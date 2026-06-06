# Troubleshooting Guide

> **How to use this guide:** Find your exact error message or symptom. Each entry shows what it means, why it happens, and the exact commands to fix it.

---

## Terraform Issues

### `Error: Error acquiring the state lock`

```
Error: Error acquiring the state lock
Lock Info:
  ID: abc-123
  Path: intelliops-tfstate-yourname/dev/terraform.tfstate
  Operation: OperationTypeApply
  Created: 2024-01-15 10:30:00
```

**Why:** A previous `terraform apply` or `destroy` crashed without releasing the DynamoDB lock. Or two people ran Terraform simultaneously.

**Fix:**
```bash
# Verify no Terraform process is actually running
ps aux | grep terraform

# If no process is running, force-unlock:
terraform force-unlock abc-123    # Use the ID from the error message
# Type 'yes' to confirm
```

---

### `Error: creating EKS Cluster: ResourceInUseException`

```
Error: creating EKS Cluster (intelliops-dev): ResourceInUseException:
  Cluster already exists with name: intelliops-dev
```

**Why:** The cluster exists in AWS but not in Terraform state (state was lost, or someone created it manually).

**Fix:**
```bash
# Import the existing cluster into state
terraform import module.eks.aws_eks_cluster.main intelliops-dev

# Then retry apply
terraform apply -auto-approve
```

---

### Terraform destroy tries to CREATE resources

**Why:** When a resource (like the EKS cluster) is manually deleted before running Terraform, `terraform plan` detects the resource is missing and tries to create it.

**Fix:** Use `-refresh=false` to skip the AWS API check:
```bash
terraform destroy -auto-approve -refresh=false
```

`destroy-stack.sh` already uses this flag automatically.

---

## kubectl / Cluster Access

### `Unable to connect to the server: dial tcp: lookup ...`

```
Unable to connect to the server: dial tcp: lookup
ABC123.gr7.us-east-1.eks.amazonaws.com: no such host
```

**Why:** kubeconfig is pointing to a cluster that no longer exists, or you haven't configured kubeconfig for the new cluster.

**Fix:**
```bash
aws eks update-kubeconfig --name intelliops-dev --region us-east-1
kubectl get nodes   # Verify connectivity
```

---

### `error: You must be logged in to the server (Unauthorized)`

**Why:** The IAM credentials used for kubectl don't have access to this EKS cluster. EKS access is controlled via aws-auth ConfigMap.

**Fix:**
```bash
# Verify your current AWS identity
aws sts get-caller-identity

# Check aws-auth ConfigMap
kubectl describe configmap aws-auth -n kube-system

# If your IAM role isn't in the map, add it via Terraform or eksctl:
eksctl create iamidentitymapping \
  --cluster intelliops-dev \
  --arn arn:aws:iam::123456789:role/my-role \
  --group system:masters \
  --username admin
```

---

## install-stack.sh Issues

### Script stops at any step

```
[ERROR] Step 12 failed: timed out waiting for helm install
```

**Fix:** Just re-run the script. It automatically resumes from the last successful checkpoint:
```bash
./scripts/install-stack.sh
# Skips already-completed steps
```

**Re-run from a specific step:**
```bash
./scripts/install-stack.sh --from=12
# Runs from step 12 onwards
```

**Reset all checkpoints (start over):**
```bash
./scripts/install-stack.sh --reset
```

---

### Step 1 (cert-manager) fails: `CRD already exists`

```
Error: INSTALLATION FAILED: cannot re-use a name that is still in use
```

**Fix:**
```bash
# Check what's there
helm list -n cert-manager

# If a failed/incomplete install exists, uninstall first
helm uninstall cert-manager -n cert-manager
kubectl delete namespace cert-manager
sleep 30

# Re-run the script from step 1
./scripts/install-stack.sh --from=1
```

---

### Step 2 (ESO) fails: `ExternalSecrets have stuck finalizers`

**Why:** Deleting ESO while ExternalSecrets exist leaves CRDs with finalizers that prevent deletion.

**Fix:**
```bash
# Remove finalizers from all ExternalSecrets
kubectl get externalsecret -A -o json | \
  jq '.items[] | "kubectl patch externalsecret " + .metadata.name +
      " -n " + .metadata.namespace +
      " -p '\''[{\"op\":\"remove\",\"path\":\"/metadata/finalizers\"}]'\'' --type=json"' -r | bash

# Then retry ESO install
./scripts/install-stack.sh --from=2
```

---

### Step 9 (Linkerd) fails: `certificate error`

```
Error: INSTALLATION FAILED: failed to render chart: exec /linkerd-cni-install.sh:
  certificate signed by unknown authority
```

**Why:** Linkerd requires pre-created certificates. The install script generates them with `step` CLI and stores in Secrets Manager. If SM doesn't have them (SM was deleted and recreated), Linkerd can't start.

**Fix:**
```bash
# Regenerate Linkerd certificates
./scripts/install-stack.sh --from=9
# The script regenerates certs automatically before Linkerd install
```

---

### Step 15b (OTEL Operator) fails: `webhook server TLS cert not ready`

```
Error: INSTALLATION FAILED: timed out waiting for condition
Waiting for webhook to be ready...
```

**Why:** The OTEL Operator webhook needs a TLS certificate from cert-manager. cert-manager might not have issued it yet.

**Fix:**
```bash
# Wait and retry
sleep 60
./scripts/install-stack.sh --from=15b

# If still failing, check cert-manager pods
kubectl get pods -n cert-manager
kubectl logs -n cert-manager deployment/cert-manager
```

---

## Pods Not Starting

### Pod in `Pending` state

```bash
kubectl describe pod <pod-name> -n <namespace>
```

**Common reasons:**

```
Events:
  Warning  FailedScheduling  0/4 nodes are available:
    4 Insufficient memory.
```
→ Nodes are full. Either scale node group or reduce other pods.

```
Events:
  Warning  FailedScheduling  0/4 nodes are available:
    4 node(s) didn't match Pod's node affinity/selector.
```
→ Pod requires specific node labels. Check the pod's `nodeSelector` or `affinity`.

---

### Pod in `CrashLoopBackOff`

```bash
# Get logs from the crashed container
kubectl logs -n apps pod/<pod-name> --previous
# --previous shows logs from the last crash, before the restart

# Common causes and fixes:
```

**Missing secret:**
```
Error: environment variable POSTGRES_PASSWORD not set
```
→ Check ESO sync: `kubectl get externalsecret -n <ns>` — look for `SecretSyncError`
→ Check SM has the secret: `aws secretsmanager describe-secret --secret-id intelliops/dev/postgresql`

**Port already in use:**
```
Error: address already in use: 8000
```
→ Two pods starting on the same node with `hostPort` — shouldn't happen in this project

**OOMKilled:**
```
Last State: Terminated (OOMKilled)
```
→ Memory limit too low. Edit the deployment's memory limit.

---

### Pod in `ImagePullBackOff`

```
Warning  Failed  Back-off pulling image "123456789.dkr.ecr.us-east-1.amazonaws.com/intelliops-dev/order-service:abc123"
```

**Fix options:**

1. Image tag doesn't exist:
```bash
aws ecr list-images --repository-name intelliops-dev/order-service
# Check if the tag exists
```

2. Node can't authenticate to ECR:
```bash
# Verify node role has AmazonEC2ContainerRegistryReadOnly
aws iam list-attached-role-policies --role-name intelliops-dev-node-role
```

3. Image was never pushed:
```bash
# Manually build and push (or run configure-stack.sh which handles this)
./scripts/configure-stack.sh
```

---

### Pod blocked by Kyverno

```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
  resource Deployment/apps/myservice was blocked due to the following policies:
  disallow-latest-tag: autogen-check-image-tag: validation error: Image tag ':latest' is not allowed.
```

**Fix:** Update the image tag to a specific version:
```yaml
# Change:
image: nginx:latest
# To:
image: nginx:1.25.0
```

For resource limits:
```yaml
containers:
  - name: myservice
    resources:
      limits:
        cpu: "500m"
        memory: "512Mi"
```

---

## ArgoCD Issues

### Application shows `OutOfSync`

```bash
# See what's different
argocd app diff microservices

# Common causes:
# 1. HPA changed replica count — should be in ignoreDifferences
# 2. Annotation added by admission controller — add to ignoreDifferences
# 3. Real drift from manual kubectl edit — ArgoCD will self-heal in 3 min
```

**Force sync immediately:**
```bash
argocd app sync microservices
```

---

### Application stuck in `Progressing`

```bash
# Check the specific resource that's blocking
argocd app get microservices

# Look for resources stuck in Progressing
argocd app resources microservices

# Check pod events for that resource
kubectl describe pod <stuck-pod> -n apps
```

---

### ArgoCD can't login

```bash
# Get the admin password from Secrets Manager
aws secretsmanager get-secret-value \
  --secret-id intelliops/dev/argocd \
  --query SecretString --output text | jq -r .admin_password

# Or from the K8s secret (if ESO has synced it)
kubectl get secret argocd-credentials -n argocd -o jsonpath='{.data.admin_password}' | base64 -d
```

---

## Observability Issues

### Prometheus scraping fails for a service

```bash
# Check ServiceMonitor exists
kubectl get servicemonitor -n monitoring

# Check Prometheus targets
# Prometheus UI: Status → Targets
# Or:
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring
# Open: http://localhost:9090/targets
# Look for the service — check "Error" column
```

**Common cause:** ServiceMonitor label doesn't match:
```yaml
# ServiceMonitor must have the label that Prometheus looks for:
labels:
  release: kube-prometheus-stack    # Must match prometheus.serviceMonitorSelector
```

---

### Grafana shows "No data"

```bash
# 1. Check the data source is connected
# Grafana → Configuration → Data Sources → each should show "Data source connected"

# 2. Check Prometheus has the metric
# Prometheus → Graph → type the metric name
# If it exists there but not in Grafana: it's a query or time range issue

# 3. Check the time range in Grafana
# Make sure "Last 5 minutes" or similar is selected, not a custom range in the future
```

---

### Loki shows no logs

```bash
# Check Promtail is running on all nodes
kubectl get pods -n monitoring -l app.kubernetes.io/name=promtail
# Should have 1 pod per node

# Check Promtail is successfully sending to Loki
kubectl logs -n monitoring daemonset/promtail | grep "Successfully"

# Check Loki is healthy
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki

# Try a simple query in Grafana Explore:
{namespace="apps"}
# If this returns nothing, Promtail is not sending to Loki
```

---

### Tempo shows no traces

```bash
# Check OTEL Collector is running
kubectl get pods -n monitoring -l app.kubernetes.io/name=opentelemetry-collector

# Check if OTEL Operator injected the instrumentation
kubectl describe pod -n apps <order-service-pod> | grep -A5 "Init Containers"
# Should show: opentelemetry-auto-instrumentation init container

# If init container is missing, check the Instrumentation CRD exists:
kubectl get instrumentation -n apps

# Check OTEL Operator is running
kubectl get pods -n monitoring -l app.kubernetes.io/name=opentelemetry-operator

# Check pod annotation
kubectl get pod -n apps <order-service-pod> -o yaml | grep inject-python
# Should show: instrumentation.opentelemetry.io/inject-python: "true"
```

---

## Security Issues

### External Secrets not syncing

```bash
kubectl get externalsecret -A
# If STATUS = SecretSyncError:
kubectl describe externalsecret <name> -n <namespace>

# Common causes:
# 1. SM secret doesn't exist yet
aws secretsmanager describe-secret --secret-id intelliops/dev/grafana

# 2. ESO IRSA role doesn't have permission
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::ACCOUNT:role/intelliops-dev-eso-irsa \
  --action-names secretsmanager:GetSecretValue \
  --resource-arns arn:aws:secretsmanager:us-east-1:ACCOUNT:secret:intelliops/dev/grafana-*

# 3. ESO pod can't get IRSA credentials
kubectl logs -n external-secrets deployment/external-secrets | grep -i error
```

---

### Kyverno blocking unexpected pods

```bash
# See all policy violations
kubectl get policyreport -A

# Check why a specific pod was blocked
kubectl get events -n apps --field-selector reason=PolicyViolation

# Temporarily put a policy into Audit mode (to debug without blocking):
kubectl patch clusterpolicy require-resource-limits \
  -p '{"spec":{"validationFailureAction":"Audit"}}' --type=merge
# Remember to set back to Enforce after debugging
```

---

### Cosign signature verification fails

```bash
# Manually verify an image signature
IMAGE="<your-ecr>.dkr.ecr.us-east-1.amazonaws.com/intelliops-dev/order-service:<sha>"
cosign verify \
  --certificate-identity-regexp="github.com/nabilpurkar/intelliops-sherlock" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  "${IMAGE}"

# If verification fails and you need to disable temporarily:
kubectl patch clusterpolicy verify-image-signatures \
  -p '{"spec":{"validationFailureAction":"Audit"}}' --type=merge
# Only do this temporarily — sign the image properly then re-enable
```

---

## Ingress / DNS Issues

### Ingress has no ADDRESS

```bash
kubectl get ingress -A
# If ADDRESS column is empty after 5 minutes:

# Check ALB controller logs
kubectl logs -n kube-system deployment/aws-load-balancer-controller | tail -50

# Common causes:
# 1. ALB controller IRSA role doesn't have the right permissions
# 2. Subnets missing the kubernetes.io/role/elb: 1 tag
# 3. VPC has no internet gateway

# Check subnet tags
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$(terraform output vpc_id)" \
  --query 'Subnets[].{ID:SubnetId,Tags:Tags}' \
  --output table
```

---

### Route53 records not created

```bash
# Check ExternalDNS is running
kubectl get pods -n external-dns

# Check ExternalDNS logs
kubectl logs -n external-dns deployment/external-dns | grep -E "Desired|error"

# Manually check Route53
aws route53 list-resource-record-sets \
  --hosted-zone-id $(aws route53 list-hosted-zones --query 'HostedZones[0].Id' --output text | cut -d/ -f3) \
  --query 'ResourceRecordSets[?contains(Name, `yourdomain`)].[Name,Type]' \
  --output table
```

---

## AIOps Issues

### AI agent not processing SQS messages

```bash
# Check AI agent is running
kubectl get pods -n aiops-demo -l app=ai-agent

# Check logs
kubectl logs -n aiops-demo deployment/ai-agent -f

# Common causes:
# 1. SQS_QUEUE_URL in ConfigMap is wrong
kubectl get configmap aiops-config -n aiops-demo -o yaml

# 2. IRSA role not attached properly
kubectl describe serviceaccount ai-agent -n aiops-demo
# Should show: eks.amazonaws.com/role-arn annotation

# 3. Bedrock model access not granted
aws bedrock list-foundation-models --region us-east-1 | grep claude
```

---

### Anomaly detector not sending to SQS

```bash
# Check if model trained successfully
kubectl logs -n aiops-demo deployment/anomaly-detector -c train-model

# Check main container
kubectl logs -n aiops-demo deployment/anomaly-detector

# Check Prometheus is reachable from aiops-demo namespace
kubectl exec -n aiops-demo deployment/anomaly-detector -- \
  curl -s http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/api/v1/status/config | head -5
```

---

## destroy-stack.sh Issues

### Script hangs at `Uninstalling external-secrets`

```bash
# Run the destroy script — it handles this with --no-hooks --wait=false
./scripts/destroy-stack.sh

# If running manually:
helm uninstall external-secrets -n external-secrets --no-hooks --wait=false
# Then remove finalizers from ExternalSecret objects
kubectl get externalsecret -A -o json | \
  jq '.items[].metadata | "kubectl patch externalsecret " + .name +
      " -n " + .namespace + " -p '\''[{\"op\":\"remove\",\"path\":\"/metadata/finalizers\"}]'\'' --type=json"' -r | bash
```

---

### Namespace stuck in `Terminating`

```bash
# Find what's blocking termination
kubectl get namespace <ns> -o json | jq '.spec.finalizers'
kubectl api-resources --verbs=list --namespaced -o name | \
  xargs -I{} kubectl get {} --ignore-not-found -n <ns>

# Force-remove namespace finalizer
kubectl get namespace <ns> -o json | \
  jq '.spec.finalizers = []' | \
  kubectl replace --raw "/api/v1/namespaces/<ns>/finalize" -f -
```

---

### Terraform destroy fails: `DependencyViolation`

```
Error: deleting Security Group (sg-abc123):
  DependencyViolation: resource sg-abc123 has a dependent object
```

**Why:** AWS resources (like the ALB) are still using the security group.

**Fix:**
```bash
# Wait for ALB to be deleted first (takes 2-3 minutes after helm uninstall)
sleep 120
terraform destroy -auto-approve -refresh=false

# If still failing, find what's using the SG:
aws ec2 describe-network-interfaces \
  --filters Name=group-id,Values=sg-abc123 \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status,Desc:Description}'
# Manually delete the ALB or the ENI blocking deletion
```

---

## Quick Diagnostic Commands

```bash
# Overall cluster health
kubectl get nodes -o wide
kubectl get pods -A | grep -v Running | grep -v Completed

# Check ArgoCD sync status
kubectl get applications -n argocd

# Check all external-facing ingresses
kubectl get ingress -A

# Check all certificates
kubectl get externalsecret -A
kubectl get certificates -A

# Check Kyverno policies
kubectl get clusterpolicy

# Check Falco is running
kubectl get pods -n falco

# Check HPA status
kubectl get hpa -n apps

# Check recent events (last 10 minutes)
kubectl get events -A --sort-by='.lastTimestamp' | tail -30

# Check Prometheus targets (is everything being scraped?)
# kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring
# Open: http://localhost:9090/targets

# Check ArgoCD app health
argocd app list
```

---

## Getting More Help

1. **Check the docs:** Each `docs/XX-topic.md` has troubleshooting relevant to that component
2. **Check the issue tracker:** Search for your error in [GitHub Issues](https://github.com/nabilpurkar/intelliops-sherlock/issues)
3. **Enable debug logging:** Most tools have a `LOG_LEVEL=debug` environment variable
4. **Check tool-specific status endpoints:**
   - Prometheus: `https://prometheus.yourdomain.com/-/healthy`
   - ArgoCD: `argocd app get <name> --show-operation`
   - Loki: `kubectl port-forward svc/loki 3100:3100 -n monitoring` → `http://localhost:3100/ready`
