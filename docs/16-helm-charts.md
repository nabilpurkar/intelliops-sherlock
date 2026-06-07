# Adding New Helm Charts

> **What you'll learn:** When to use Helm vs plain YAML, how to vendor a new chart, write values files, create an ArgoCD Application, manage upgrades, and handle breaking changes — all following the no-hardcoded-secrets constraint.

---

## When to Use Helm vs Plain YAML

| Use Helm | Use plain YAML |
|----------|---------------|
| Third-party software (databases, monitoring tools, security tools) | Your own microservices |
| Charts with 50+ resources | Simple Deployments + Services |
| Software that needs version tracking and upgrade paths | Resources that rarely change |
| When official support exists (e.g., `prometheus-community/kube-prometheus-stack`) | Resources managed directly by ArgoCD sync |

**Rule of thumb:** If you'd `helm install` it, put it in `k8s/helm-charts/`. If you'd `kubectl apply` it, put it in `k8s/apps/`.

---

## Directory Structure

```
k8s/
├── helm-charts/          ← Vendored chart tarballs (extracted)
│   ├── prometheus/       ← Chart source files
│   ├── loki/
│   └── my-new-chart/     ← Your new chart goes here
│
├── helm-values/          ← Your customisation per chart
│   ├── kube-prometheus-values.yaml
│   ├── loki-values.yaml
│   └── my-new-chart-values.yaml   ← Your values file
│
└── argocd/
    └── platform/
        ├── prometheus-app.yaml
        ├── loki-app.yaml
        └── my-new-chart-app.yaml  ← ArgoCD Application
```

---

## Step-by-Step: Adding a New Chart

### Step 1: Find the chart and check the version

```bash
# Search Artifact Hub
helm search hub <chart-name>

# Or search a specific repo
helm repo add bitnami https://charts.bitnami.com/bitnami
helm search repo bitnami/<chart-name> --versions | head -5

# Check what the latest stable version is
helm show chart bitnami/<chart-name> | grep version
```

### Step 2: Vendor the chart (pull source into the repo)

Vendoring means copying the chart source into the repository so ArgoCD can read it without needing Helm repo access at sync time. This also pins the exact chart version.

```bash
cd k8s/helm-charts

# Pull and extract the chart
helm pull <repo>/<chart-name> --version <version> --untar --untardir .

# Example: adding Vault
helm repo add hashicorp https://helm.releases.hashicorp.com
helm pull hashicorp/vault --version 0.28.1 --untar --untardir .
# Creates: k8s/helm-charts/vault/
```

Commit the vendored chart:

```bash
git add k8s/helm-charts/<chart-name>/
git commit -m "chore: vendor <chart-name> v<version>"
```

> **Why vendor?** ArgoCD runs inside the cluster with no outbound access to public Helm repos. Vendoring means ArgoCD reads the chart from the git repo itself — offline, auditable, and version-pinned.

### Step 3: Inspect and extract default values

```bash
# See all configurable values (hundreds for complex charts)
helm show values k8s/helm-charts/<chart-name>/ > /tmp/<chart-name>-defaults.yaml

# Read through and identify what you need to override
cat /tmp/<chart-name>-defaults.yaml | grep -A3 "ingress:"
```

### Step 4: Write a values override file

Create `k8s/helm-values/<chart-name>-values.yaml`. Only include values you're changing — Helm merges your overrides with the chart defaults.

```yaml
# k8s/helm-values/vault-values.yaml
# chart: hashicorp/vault version 0.28.1
# install: helm upgrade --install vault hashicorp/vault --version 0.28.1 -n vault --create-namespace -f vault-values.yaml

server:
  replicas: 1
  ingress:
    enabled: false                  # Kong handles ingress — disable chart's own

  # Secrets loaded from AWS SM via ExternalSecrets — never hardcode here
  extraEnvVars:
    - name: VAULT_SEAL_KEY
      valueFrom:
        secretKeyRef:
          name: vault-unseal-secret   # Created by ExternalSecret below
          key: unseal_key

  resources:
    requests:
      cpu: "250m"
      memory: "256Mi"
    limits:
      cpu: "500m"
      memory: "512Mi"

ui:
  enabled: true
  serviceType: ClusterIP

injector:
  enabled: false     # Using ESO (External Secrets Operator) instead
```

**Security rule:** If the chart accepts passwords or tokens as values, pass them via `valueFrom.secretKeyRef` pointing to an `ExternalSecret`-created k8s Secret — never as literal strings in the values file.

### Step 5: Create ExternalSecrets for chart credentials

If the chart needs secrets (database passwords, API keys, TLS certificates), create an ExternalSecret **before** the ArgoCD Application:

```yaml
# k8s/apps/vault-secrets.yaml  (or k8s/platform-secrets/vault-secrets.yaml)
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: vault-unseal-secret
  namespace: vault
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: vault-unseal-secret
    creationPolicy: Owner
  data:
    - secretKey: unseal_key
      remoteRef:
        key: intelliops/dev/vault
        property: unseal_key
```

Store the secret in AWS SM first:

```bash
aws secretsmanager create-secret \
  --name intelliops/dev/vault \
  --secret-string '{"unseal_key":"s.XXXXXXXXXX"}' \
  --region us-east-1
```

### Step 6: Create the ArgoCD Application

Create `k8s/argocd/platform/<chart-name>-app.yaml`:

```yaml
# k8s/argocd/platform/vault-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: vault
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "3"   # Deploy after secrets are ready (wave 2)
spec:
  project: intelliops
  sources:
    - repoURL: https://github.com/nabilpurkar/intelliops-sherlock.git
      path: k8s/helm-charts/vault        # Vendored chart source
      targetRevision: main
      helm:
        valueFiles:
          - $values/k8s/helm-values/vault-values.yaml
    - repoURL: https://github.com/nabilpurkar/intelliops-sherlock.git
      ref: values                         # Alias for the values source
      targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: vault
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 30s
        factor: 2
        maxDuration: 15m
```

### Step 7: Register the Application in ArgoCD

Add the new Application to the platform ArgoCD Application (the "App of Apps"):

```bash
# Apply directly (ArgoCD will pick it up and start managing the new app)
kubectl apply -f k8s/argocd/platform/vault-app.yaml

# Or commit and let ArgoCD self-sync (takes ~3 min)
git add k8s/argocd/platform/vault-app.yaml k8s/helm-charts/vault/ k8s/helm-values/vault-values.yaml
git commit -m "feat: add vault helm chart"
git push origin main
```

### Step 8: Verify deployment

```bash
# Watch ArgoCD sync the new application
kubectl get application vault -n argocd -w

# Check pods
kubectl get pods -n vault

# Check events if pods are stuck
kubectl get events -n vault --sort-by='.lastTimestamp' | tail -20
```

---

## Sync Waves — Deploy Order

Sync waves control the order in which ArgoCD applies resources. Use them to ensure prerequisites exist before dependent apps:

```
Wave -1:  Namespace creation, CRDs
Wave  0:  Core infrastructure (cert-manager, ESO, external-dns)
Wave  1:  Secret stores (aws-secrets-manager ClusterSecretStore)
Wave  2:  Secrets (ExternalSecrets that create k8s Secrets)
Wave  3:  Applications that consume those secrets
Wave  4:  Applications that depend on wave-3 apps
```

Set the wave in the Application annotation:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "3"
```

If your new chart depends on another chart being up first, use a higher wave number.

---

## Upgrading a Chart

When a new version of a vendored chart is released:

```bash
# 1. Pull the new version
cd k8s/helm-charts
helm pull bitnami/redis --version 20.0.0 --untar --untardir .
# This overwrites the existing directory

# 2. Check for breaking changes in the chart's CHANGELOG or README
cat k8s/helm-charts/redis/CHANGELOG.md | head -100

# 3. Check if values file needs updating
helm show values k8s/helm-charts/redis/ > /tmp/redis-new-defaults.yaml
diff <(helm show values k8s/helm-charts/redis-old/) /tmp/redis-new-defaults.yaml | grep "^[<>]"
# Look for keys that were renamed or removed

# 4. Update the comment at top of values file
# chart: bitnami/redis version 20.0.0   ← update version here

# 5. Commit and push — ArgoCD auto-deploys the upgrade
git add k8s/helm-charts/redis/ k8s/helm-values/redis-values.yaml
git commit -m "chore: upgrade redis chart 19.x -> 20.0.0"
git push origin main

# 6. Watch the upgrade rollout
kubectl get pods -n <namespace> -w
```

### Rolling back a chart upgrade

```bash
# Option 1: git revert (preferred — restores previous chart version)
git revert HEAD
git push origin main
# ArgoCD detects the revert and deploys the old chart

# Option 2: ArgoCD rollback to previous sync
argocd app history <app-name>
argocd app rollback <app-name> <revision-id>
```

---

## ignoreDifferences — Handling Chart Defaults

Some charts set fields at deploy time (e.g., `creationTimestamp`, random job names, auto-generated tokens) that cause ArgoCD to report OutOfSync continuously. Fix with `ignoreDifferences`:

```yaml
# Common patterns — add to the Application spec
ignoreDifferences:
  # Chart sets creationTimestamp: null but cluster gets a real timestamp
  - group: ""
    kind: ConfigMap
    jsonPointers:
      - /metadata/creationTimestamp

  # Timed jobs (e.g., DefectDojo initializer creates Job with timestamp in name)
  - group: batch
    kind: Job
    jsonPointers:
      - /status

  # Webhook caBundle injected by cert-manager at runtime
  - group: admissionregistration.k8s.io
    kind: ValidatingWebhookConfiguration
    jsonPointers:
      - /webhooks/0/clientConfig/caBundle

  # HPA owns replica count at runtime
  - group: apps
    kind: Deployment
    jsonPointers:
      - /spec/replicas
```

---

## Adding a Kong Ingress for the New Chart

If the chart exposes a UI or API that should be accessible externally, add a Kong ingress. Do NOT use `ingress.enabled: true` in the chart values — Kong is the single ingress controller.

```yaml
# k8s/ingress/ingress-<chart-name>.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: vault
  namespace: vault
  annotations:
    konghq.com/strip-path: "false"
spec:
  ingressClassName: kong
  rules:
    - host: vault.infrastructurepath.online
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: vault-ui
                port:
                  number: 8200
```

---

## Adding a ServiceMonitor for Chart Metrics

If the chart exposes Prometheus metrics:

```yaml
# Add to values file — most charts have a serviceMonitor section
serviceMonitor:
  enabled: true
  namespace: monitoring    # Where Prometheus looks for ServiceMonitors
  labels:
    release: kube-prometheus-stack   # Label Prometheus requires
  interval: 30s
  path: /metrics
```

Or create a standalone ServiceMonitor:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: vault-metrics
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames: [vault]
  selector:
    matchLabels:
      app.kubernetes.io/name: vault
  endpoints:
    - port: http-internal
      path: /v1/sys/metrics
      params:
        format: [prometheus]
      interval: 30s
```

---

## Checklist: New Helm Chart

```
Preparation
  [ ] Chart version identified and pinned
  [ ] CHANGELOG reviewed for breaking changes
  [ ] Default values reviewed with: helm show values

Vendoring
  [ ] helm pull --untar into k8s/helm-charts/<chart-name>/
  [ ] Version comment added to values file

Values file
  [ ] Only overrides (not the full defaults)
  [ ] No literal secrets — all from secretKeyRef
  [ ] Resources limits set for main container
  [ ] chart.ingress.enabled: false (Kong handles routing)

Secrets
  [ ] AWS SM secret created for any credentials
  [ ] ExternalSecret YAML written referencing AWS SM path
  [ ] ExternalSecret synced before app deploys (lower sync-wave)

ArgoCD Application
  [ ] Two-source pattern (chart + values from same repo)
  [ ] Correct sync-wave (higher than its dependencies)
  [ ] ignoreDifferences added for known drift fields
  [ ] Applied and showing Synced + Healthy

Observability
  [ ] ServiceMonitor or podMonitor created if chart exposes /metrics
  [ ] Grafana dashboard created (or use chart's built-in if bundled)

Access
  [ ] Kong ingress created if UI/API needs external access
```

---

## What's Next?

→ **[17-one-click-automation.md](17-one-click-automation.md)** — Full one-click deployment automation
→ **[09-argocd-gitops.md](09-argocd-gitops.md)** — ArgoCD sync policies and App of Apps pattern
→ **[13-troubleshooting.md](13-troubleshooting.md)** — Chart OutOfSync and upgrade failures
