# ArgoCD & GitOps Guide

> **What you'll learn:** What GitOps is and why it's better than push-based CD, how ArgoCD is configured in this project, what the three Applications do, how sync policies work, and how to troubleshoot common ArgoCD issues.

---

## What Is GitOps?

GitOps is a deployment model where **git is the single source of truth for cluster state**. The rule: if something runs in the cluster, it must be declared in git. If something is in git, ArgoCD deploys it automatically.

**The shift from push-based CD:**

```
Traditional "push" CD (what most teams start with):
  CI passes → CI calls kubectl apply → pod updates
  Problems:
    - CI has admin credentials (blast radius if CI is compromised)
    - Cluster state drifts if someone runs kubectl manually
    - No rollback via git — must re-run old CI job
    - No visibility into "what's actually running" vs "what CI last deployed"

GitOps "pull" CD (what ArgoCD provides):
  CI passes → CI commits new image tag to git → done
  ArgoCD (inside cluster) watches git → detects change → applies update
  Benefits:
    - No external system has cluster credentials
    - Manual changes are detected and reverted (self-heal)
    - Rollback = git revert
    - ArgoCD UI shows exact state: deployed vs desired
```

---

## ArgoCD Architecture

```
GitHub Repo (intelliops-sherlock)
  k8s/apps/*.yaml     ← what SHOULD run (desired state)
  k8s/deployments/*.yaml
  k8s/locust/*.yaml
         │
         │  ArgoCD polls every 3 minutes (or webhook-triggered)
         ▼
  ArgoCD Application Controller
    Compares: git state vs cluster state
    If different: sync (apply changes)
    If identical: nothing to do (Synced + Healthy)
         │
         ▼
  Kubernetes cluster
    apps namespace: 3 microservices
    aiops-demo namespace: 4 AIOps workloads
    locust namespace: load generator
```

---

## Three Applications

ArgoCD manages three `Application` resources — each watches a different directory in git:

### Application 1: microservices

```yaml
source:
  path: k8s/apps                # Watches this directory
destination:
  namespace: apps               # Deploys to this namespace
```

**What it manages:**
- `_bootstrap.yaml` — ServiceAccount, ConfigMap (deployed first due to `_` prefix sort)
- `order-service.yaml` — Deployment, Service, HPA, ServiceMonitor
- `payment-service.yaml`
- `inventory-service.yaml`
- `otel-instrumentation.yaml` — Instrumentation CRD for OTEL auto-inject

**Sync trigger:** When CI commits a new image tag to `k8s/apps/order-service.yaml`, ArgoCD detects the change and rolls out the new image.

---

### Application 2: aiops

```yaml
source:
  path: k8s/deployments         # AIOps workloads
destination:
  namespace: aiops-demo
```

**What it manages:**
- `anomaly-detector.yaml` — ML-based anomaly detection service
- `alert-correlator.yaml` — Groups related alerts
- `forecaster.yaml` — Time-series forecasting
- `ai-agent.yaml` — Claude Sonnet-powered auto-remediation agent

---

### Application 3: locust

```yaml
source:
  path: k8s/locust              # Load generator
destination:
  namespace: locust
```

**What it manages:**
- Locust deployment and service
- ConfigMap with locustfile (defines traffic patterns)

---

## AppProject — Security Boundary

The `AppProject` named `intelliops` constrains what ArgoCD can do:

```yaml
spec:
  sourceRepos:
    - https://github.com/nabilpurkar/intelliops-sherlock.git
    # Only this repo — ArgoCD can't deploy from any other source

  destinations:
    - server: https://kubernetes.default.svc
      namespace: apps
    - namespace: locust
    - namespace: aiops-demo
    # ArgoCD can ONLY deploy to these three namespaces
    # Even if someone adds a malicious Application pointing to kube-system,
    # the AppProject blocks it

  namespaceResourceWhitelist:
    - { group: "apps", kind: Deployment }
    - { group: "", kind: Service }
    - { group: "", kind: ConfigMap }
    - { group: "autoscaling", kind: HorizontalPodAutoscaler }
    # ArgoCD can only manage these resource types
    # Cannot create ClusterRoles, PersistentVolumes, etc.

  clusterResourceWhitelist:
    - { group: "", kind: Namespace }
    # The only cluster-scoped resource it can manage is Namespace
```

**Why this matters:** Without AppProject restrictions, a compromised git repo or CI pipeline could add an ArgoCD Application that deploys malicious workloads to `kube-system`. The AppProject acts as the least-privilege boundary for GitOps.

---

## Sync Policy Details

```yaml
syncPolicy:
  automated:
    prune: true      # If a resource is deleted from git, delete it from cluster
    selfHeal: true   # If someone manually edits a resource, revert to git

  syncOptions:
    - CreateNamespace=false      # Namespace pre-created by install-stack.sh
    - ApplyOutOfSyncOnly=true    # Skip re-applying already-synced resources
    - ServerSideApply=true       # Uses kubectl apply --server-side (handles large objects)

  retry:
    limit: 5           # Retry sync up to 5 times
    backoff:
      duration: 5s     # Wait 5s before first retry
      factor: 2        # Double wait each time: 5s, 10s, 20s, 40s, 80s
      maxDuration: 3m  # Cap at 3 minutes
```

### prune: true — Why It Matters

If you delete `k8s/apps/old-service.yaml` from git:
- Without `prune: true`: The old-service Deployment stays in the cluster forever
- With `prune: true`: ArgoCD deletes the Deployment from the cluster when the file is removed from git

This is how "git is the source of truth" works — deleting from git = deleting from cluster.

### selfHeal: true — Drift Detection

```bash
# What happens without selfHeal:
kubectl scale deployment order-service -n apps --replicas=5
# Someone manually scales to 5 — ArgoCD notices the drift
# Without selfHeal: stays at 5 (drift persists)
# With selfHeal: ArgoCD reverts to git value (replicas: 2) within 3 minutes
```

**Exception:** `ignoreDifferences` on `spec.replicas` — ArgoCD ignores the replica count because HPA manages it at runtime. If we didn't ignore it, every time HPA scaled to 3 pods, ArgoCD would revert it to 2.

```yaml
ignoreDifferences:
  - group: apps
    kind: Deployment
    jsonPointers:
      - /spec/replicas    # HPA owns this — ArgoCD should not manage it
```

---

## How a Deployment Actually Happens

Step-by-step walk through of what happens when a developer pushes code:

```
1. Developer: git push origin main
   (Changes services/order-service/main.py)

2. GitHub Actions CI triggers:
   Stage 1-7: Secret scan, SAST, SCA, tests, SonarQube, IaC scan, build
   Stage 8: Build + push image to ECR:
     123456789.dkr.ecr.us-east-1.amazonaws.com/intelliops-dev/order-service:abc1234
   Stage 9: Manifest update job:
     Checks out platform repo
     Runs: sed -i "s|:old_sha|:abc1234|" k8s/apps/order-service.yaml
     Commits: "ci: update order-service to sha-abc1234"
     Pushes to main

3. ArgoCD polls GitHub every 3 minutes (or webhook triggers immediately)
   Detects k8s/apps/order-service.yaml changed
   Computes diff: current running image vs new image tag

4. ArgoCD syncs:
   kubectl apply -f k8s/apps/order-service.yaml --server-side
   Kubernetes rolling update begins:
     - Creates new pod with new image
     - Waits for readiness probe
     - Terminates old pod
     - Repeats for second replica

5. ArgoCD shows: Synced + Healthy

6. Stage 10: Optional ArgoCD sync trigger (skip the 3-min poll):
   argocd app sync microservices --auth-token "${ARGOCD_AUTH_TOKEN}"
```

---

## ArgoCD UI Guide

**URL:** `https://argocd.yourdomain.com`

### Main Dashboard

You'll see 3 application cards:
- **microservices** — Green (Synced + Healthy)
- **aiops** — Green (Synced + Healthy)
- **locust** — Green (Synced + Healthy)

Click any card to drill in.

### Application Detail View

```
Tree view (default):
  microservices
  ├── Deployment/order-service    ✓ Healthy
  │   └── ReplicaSet/order-service-7d4b8f
  │       ├── Pod/order-service-7d4b8f-abc  ✓ Running
  │       └── Pod/order-service-7d4b8f-xyz  ✓ Running
  ├── Service/order-service       ✓ Healthy
  ├── HPA/order-service           ✓ Healthy (replicas: 2/2)
  └── ServiceMonitor/order-service ✓ Healthy
```

Click any resource to see its YAML, events, and logs.

### Sync Status Meanings

| Status | Meaning |
|--------|---------|
| `Synced + Healthy` | Git state = cluster state, all pods running |
| `OutOfSync` | Git changed, not yet applied |
| `Degraded` | Pods failing health checks |
| `Progressing` | Rolling update in progress |
| `Missing` | Resource in git but not in cluster |
| `Unknown` | ArgoCD can't determine health |

### Manual Sync

If you don't want to wait for the 3-minute poll:
1. Click the application card
2. Click **Sync**
3. Select resources to sync (or sync all)
4. Click **Synchronize**

Or via CLI:
```bash
argocd app sync microservices
argocd app sync aiops
```

---

## Common ArgoCD Issues

### Issue: Application stuck in Progressing

```bash
# Check which resource is blocking
argocd app get microservices --show-operation
# Look for resources in "Progressing" state

# Check pod events
kubectl describe pod -n apps <pod-name>
# Common causes:
#   - Image pull error (wrong tag, ECR auth issue)
#   - Readiness probe failing (app not starting correctly)
#   - Resource limits too low (OOMKilled)
```

### Issue: OutOfSync with no visible changes

```bash
# Get diff
argocd app diff microservices
# Shows what ArgoCD sees as different between git and cluster
# Common cause: ignoreDifferences not set for HPA-managed replica count
```

### Issue: Sync failed with "unable to replace"

```bash
# Check application events
kubectl describe application microservices -n argocd
# Common cause: annotation too large (use ServerSideApply=true — already set)
# Or: immutable field changed (delete + recreate the resource)
```

### Issue: ArgoCD can't connect to repo

```bash
# Check repo status
argocd repo list
# If connection failed, verify the GitHub token in SM is still valid
# configure-stack.sh sets ARGOCD_AUTH_TOKEN GitHub Action secret
```

---

## Rollback with ArgoCD

One of GitOps' biggest advantages: rollback is just a git operation.

```bash
# Option 1: git revert
git revert HEAD  # Reverts last commit (e.g., the image tag update)
git push origin main
# ArgoCD detects the revert commit → rolls back the deployment

# Option 2: ArgoCD history rollback (no git change)
argocd app history microservices
# Shows last 5 sync revisions

argocd app rollback microservices <revision-id>
# Rolls back to a previous revision
# Note: this creates a "sync to different commit" state — ArgoCD will
# show OutOfSync on next git commit until someone syncs forward again

# Option 3: ArgoCD UI
# Application → History → click revision → "Rollback"
```

---

## Interview Questions — ArgoCD & GitOps

**Q1: What's the difference between self-heal and prune in ArgoCD?**
> *Answer:* "`selfHeal: true` means ArgoCD actively monitors the cluster and reverts manual changes that diverge from git — if someone runs `kubectl edit deployment` and changes something, ArgoCD detects the drift and applies the git state within 3 minutes. `prune: true` means when you remove a resource from git (delete the YAML file), ArgoCD also deletes it from the cluster. Without prune, deleted YAML files would leave orphaned resources in the cluster forever. Both together give you the GitOps guarantee: cluster state = git state, always."

**Q2: Why does ArgoCD ignore `spec.replicas` with ignoreDifferences?**
> *Answer:* "The HPA (Horizontal Pod Autoscaler) dynamically changes `spec.replicas` based on CPU/memory — it might scale from 2 to 4 pods under load. If ArgoCD didn't ignore this field, it would constantly detect 'git says 2, cluster has 4' and revert the HPA's scaling decision back to 2, which would break autoscaling. We use `ignoreDifferences` with a JSON pointer to `/spec/replicas` to tell ArgoCD: 'this field is managed at runtime by HPA, don't touch it.'"

**Q3: How does ArgoCD implement the principle of least privilege?**
> *Answer:* "Two mechanisms: First, AppProject restricts what ArgoCD can deploy — which source repos, which destination namespaces, and which Kubernetes resource types. Even if someone adds a malicious Application targeting `kube-system`, the AppProject blocks it. Second, ArgoCD uses a Kubernetes ServiceAccount with RBAC scoped to only the namespaces and resources it manages. It doesn't have cluster-admin. So a compromised ArgoCD would be limited to creating Deployments, Services, ConfigMaps in the allowed namespaces — it couldn't escalate to cluster-admin or read Secrets in other namespaces."

**Q4: Walk through what happens when a developer pushes a breaking change.**
> *Answer:* "The CI pipeline runs all security and quality gates. If a gate fails (e.g., Trivy finds a critical CVE), the pipeline stops there — no image is pushed, no manifest is updated, ArgoCD never sees the change. If CI passes but the new image crashes (bad code), the Kubernetes rolling update pauses: the readiness probe on the new pod fails, Kubernetes stops the rollout and keeps old pods running. The deployment shows Progressing in ArgoCD but doesn't complete. The developer sees pod CrashLoopBackOff events and can diagnose. Rollback is `git revert` + push — ArgoCD deploys the previous image. At no point does the broken code serve production traffic because the readiness probe protected the rollout."

**Q5: How is GitOps different from traditional CI/CD?**
> *Answer:* "Traditional CI/CD is 'push': the CI system has cluster credentials and directly applies changes via `kubectl apply`. The CI system is an external actor writing to the cluster. GitOps is 'pull': the cluster (ArgoCD) watches git and pulls changes in. No external system has cluster credentials. This is a significant security improvement — a compromised CI system can't deploy malicious workloads because it doesn't have write access to the cluster. Git becomes the audit trail: every deployment is a git commit with author, timestamp, and diff. Rollback is `git revert`, not 'run the old CI job'. And drift detection is automatic — if someone runs `kubectl delete` manually, ArgoCD recreates the resource."

---

## What's Next?

→ **[10-slos-alerting.md](10-slos-alerting.md)** — The SLO PrometheusRules and AlertManager config that ArgoCD deploys
→ **[11-aiops.md](11-aiops.md)** — The AIOps workloads managed by the `aiops` ArgoCD Application
→ **[13-troubleshooting.md](13-troubleshooting.md)** — Common ArgoCD OutOfSync and Progressing errors with fixes
