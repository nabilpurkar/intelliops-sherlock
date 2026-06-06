# CI/CD Pipeline Guide

> **What you'll learn:** How the 11-stage CI/CD pipeline works end to end, what each security gate catches, why it's structured this way, how image signing and SBOM generation work, and what "shift-left security" really means in practice.

---

## Why This Pipeline Exists

Imagine a developer pushes a single line of code. Before that code runs in production, you need to know:
- Did they accidentally commit an AWS key? (secret scan)
- Does the new Python dependency have a known CVE? (SCA)
- Does the code have SQL injection patterns? (SAST)
- Is the Docker base image vulnerable? (image scan)
- Is the running app exposed to XSS attacks? (DAST)
- Can you prove who built this image and when? (Cosign + SLSA)

Traditional teams check these things manually, quarterly, or not at all. This pipeline checks all of them **automatically on every push** — and blocks the deployment if any critical issue is found.

---

## Pipeline Architecture

```
Developer pushes to main branch
            │
            ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     GitHub Actions CI Pipeline                       │
│                                                                       │
│  Stage 1: Secret Scan ──────────────────────────────── BLOCKING     │
│     └── GitLeaks scans every commit for API keys, tokens, certs      │
│                                                                       │
│  Stage 2: SAST ─────────────────────────────────────── BLOCKING     │
│     └── Semgrep: Python/YAML/Terraform code patterns (auto rules)    │
│                                                                       │
│  Stage 3: SCA (Software Composition Analysis) ──────── BLOCKING     │
│     ├── Trivy FS: scans requirements.txt for vulnerable packages     │
│     └── OWASP Dependency-Check: CVSS ≥ 7 blocks pipeline            │
│                                                                       │
│  Stage 4: Unit Tests ───────────────────────────────── BLOCKING     │
│     └── pytest with coverage threshold                                │
│                                                                       │
│  Stage 5: SonarQube ────────────────────────────────── BLOCKING     │
│     └── Code quality + security hotspots (Quality Gate must pass)    │
│                                                                       │
│  Stage 6: IaC Scan (when terraform/ changed) ───────── BLOCKING     │
│     ├── Checkov: Terraform + K8s manifest security best practices    │
│     ├── tfsec: additional Terraform security rules                   │
│     ├── Conftest: OPA/Rego custom K8s policy validation              │
│     └── Infracost: cost estimate added to PR (non-blocking)          │
│                                                                       │
│  Stage 7: Docker Build + Security Gates ────────────── BLOCKING     │
│     ├── Hadolint: Dockerfile lint (no root, no ADD, no latest)       │
│     ├── Build image locally (not pushed yet)                         │
│     ├── Trivy: image scan (CRITICAL/HIGH fixable CVEs block)         │
│     ├── Syft: generate SBOM (CycloneDX + SPDX formats)               │
│     └── Grype: SBOM-based second-opinion scan (CRITICAL blocks)      │
│                                                                       │
│  Stage 8: Build + Push + Sign ──────────────────────── BLOCKING     │
│     ├── Push multi-platform image (linux/amd64 + linux/arm64)        │
│     ├── Cosign sign (keyless OIDC — no stored key material)          │
│     ├── SBOM attestation attached to image digest                    │
│     └── SLSA Level 2 provenance generated                            │
│                                                                       │
│  Stage 9: Manifest Update ──────────────────────────── BLOCKING     │
│     └── Commits new image SHA tag to k8s/apps/*.yaml in this repo   │
│                                                                       │
│  Stage 10: ArgoCD Sync ─────────────────────────────── OPTIONAL     │
│     └── Triggers ArgoCD to sync immediately (skip the 3-min poll)   │
│                                                                       │
│  Stage 11: DAST ────────────────────────────────────── NON-BLOCKING │
│     └── OWASP ZAP: baseline passive scan against running app         │
│                                                                       │
└─────────────────────────────────────────────────────────────────────┘
            │
            ▼
   All results → DefectDojo (centralized security findings aggregator)
   All SARIF → GitHub Security tab (Code Scanning alerts)
```

---

## Two-Repo Model

**Important:** The platform repo (`intelliops-sherlock`) runs **only** GitLeaks and IaC scans. The remaining stages (SAST, SCA, build, sign, DAST) run in each **service repo** (`order-service`, `payment-service`, `inventory-service`).

When a service CI pipeline completes successfully:
1. The service repo CI fires a `repository_dispatch` event to the platform repo
2. `_manifest-update.yml` in the platform repo updates `k8s/apps/<service>.yaml` with the new image SHA
3. ArgoCD detects the YAML change and deploys

This separation means:
- Service teams own their CI
- Platform team owns the manifest that controls what runs in the cluster
- No service can deploy directly — they must go through the manifest update

---

## Stage-by-Stage Breakdown

### Stage 1: Secret Scanning (GitLeaks)

**What it is:** GitLeaks is an open-source tool that scans your entire git history (not just the latest commit) for hardcoded secrets.

**What it catches:**
```
AWS_ACCESS_KEY_ID = AKIAIOSFODNN7EXAMPLE
api_key = "sk-proj-abc123..."
password = "mysupersecretpassword"
RSA private key PEM headers (base64-encoded key material)
```
Pattern matching covers: AWS key IDs (AKIA...), API tokens, password literals, PEM-encoded private keys.

**Why it matters:** Once a secret is committed to git, it exists in history forever — even if you delete the file in the next commit. GitLeaks scans history back to the repo's creation.

**Implementation:**
```yaml
# .github/workflows/_gitleaks.yml
- uses: gitleaks/gitleaks-action@v2
  with:
    fetch-depth: 0    # Full history, not just latest commit
```

**Blocking:** Yes. If a secret is found, the pipeline fails immediately.

---

### Stage 2: SAST — Static Application Security Testing (Semgrep)

**What it is:** "Semgrep is a fast, open-source, static analysis tool that finds bugs, detects vulnerabilities, and enforces code standards." — Semgrep Inc.

**What it catches (examples):**
- SQL injection patterns: `f"SELECT * FROM users WHERE id = {user_id}"`
- Hardcoded credentials in Python code
- Insecure deserialization (`pickle.loads(user_data)`)
- Path traversal: `open(user_input)` without sanitization
- Dangerous YAML loading: `yaml.load()` without `Loader=`
- Terraform IAM `"Resource": "*"` overly permissive rules

**How it works:**
```
Semgrep uses semantic analysis — it understands code structure
(AST), not just text patterns. So it catches:
  result = db.execute(f"SELECT * FROM {table}")
Even when the format string is on a separate line.
```

**Configuration:**
```yaml
semgrep scan \
  --config=auto \         # Uses Semgrep's maintained rule registry
  --severity=ERROR \      # Only block on ERROR-level (not WARNING)
  --exclude="**/.terraform/**"
```

**Blocking:** Yes — ERROR severity findings block the pipeline.

---

### Stage 3: SCA — Software Composition Analysis

**What it is:** SCA analyzes the open-source packages your code depends on (requirements.txt, package.json, go.mod) and checks them against CVE databases.

**Two tools run in parallel:**

#### Trivy FS (Aqua Security)
```
"Trivy is a comprehensive and versatile security scanner.
Trivy has scanners that look for security issues, and
targets where it can find those issues." — Aqua Security
```
- Scans the entire repository filesystem
- Checks requirements.txt against NVD + OSV databases
- Blocks on CRITICAL and HIGH fixable vulnerabilities

#### OWASP Dependency-Check
```
"OWASP dependency-check is a Software Composition Analysis (SCA)
tool that attempts to detect publicly disclosed vulnerabilities
contained within a project's dependencies." — OWASP
```
- Scans `services/` directory for all language package files
- Fails on CVSS score ≥ 7 (High and Critical)
- Generates HTML + XML + SARIF reports

**Blocking:** Yes — CRITICAL/HIGH CVEs in dependencies block the pipeline.

---

### Stage 4: Unit Tests

**What they test:** Service logic — order creation, payment processing, inventory checks — in isolation. No external dependencies, no Kubernetes.

**Why they run before the build:** No point building and scanning a Docker image if the code doesn't even pass its own tests.

---

### Stage 5: SonarQube Code Quality

**What it is:** "SonarQube is the leading tool for continuously inspecting the Code Quality and Code Security of your codebase and guiding development teams during Code Reviews." — Sonar

**What it analyzes:**
- Code smells (maintainability issues)
- Security hotspots (code that needs manual security review)
- Coverage (% of code covered by tests)
- Duplications (copy-paste code)
- Complexity (cyclomatic complexity per function)

**Quality Gate:** SonarQube has a pass/fail concept called a Quality Gate. The pipeline only continues if the Quality Gate passes. Default gate requires:
- 0 new bugs
- 0 new vulnerabilities
- Coverage ≥ 80% on new code
- Duplication < 3%

**UI:** `https://sonarqube.yourdomain.com` — browse findings, security hotspots, trends over time.

---

### Stage 6: IaC Security Scanning

This stage only runs when `terraform/` files change (detected by `dorny/paths-filter`).

#### Checkov (Bridgecrew/Palo Alto)
```
"Checkov is a static code analysis tool for infrastructure as code (IaC)
and also a software composition analysis (SCA) tool for images and
open source packages." — Bridgecrew
```
- Scans `terraform/` directory against 1000+ Terraform security rules
- Scans `k8s/` directory against Kubernetes manifest best practices
- Example rules enforced:
  - EKS cluster logging must be enabled
  - S3 buckets must have versioning
  - Pods must not run as root
  - IMDSv2 must be enforced on EC2

**Skip:** `CKV_K8S_21` is skipped (default SA check — not applicable with IRSA)

#### tfsec (Aqua Security)
Additional Terraform-specific security scanner — second opinion. Runs in parallel with Checkov.

#### Conftest (OPA)
```
"Conftest is a utility to help you write tests against structured
configuration data." — Open Policy Agent
```
Custom OPA/Rego policies in `policy/conftest/` validate K8s manifests:
- All deployments must have resource limits set
- All deployments must have health probes
- Images must come from the ECR registry only

**Example Rego policy:**
```rego
deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  not container.resources.limits
  msg := sprintf("Container %s has no resource limits", [container.name])
}
```

#### Infracost (Non-blocking)
```
"Infracost shows cloud cost estimates for Terraform.
It lets engineers see a cost breakdown and understand costs
before making changes." — Infracost
```
- Shows monthly cost breakdown in the PR comment
- Non-blocking — informational only
- Example output: "This change adds $12.50/month (ALB + 1 extra node)"

---

### Stage 7: Docker Image Security Gates

This is the most thorough stage. The image is **built locally, scanned, then pushed** — never the other way around.

#### Step 1: Hadolint (Dockerfile Lint)
```
"Hadolint is a Dockerfile linter that helps build best practice
Docker images." — Hadolint
```
Example violations it catches:
- `FROM python:3.12` (no SHA pin — use `:3.12-slim@sha256:...`)
- `USER root` after app is set up
- `ADD http://example.com/file.tar.gz /app` (use COPY, not ADD for URLs)
- `RUN apt-get update && apt-get install` on separate lines (creates extra layers)

#### Step 2: Build locally (not pushed)
The image is built with `--load` (local docker daemon) tagged as `scan-<sha>`. This image never leaves the runner — it's only used for scanning.

#### Step 3: Trivy Image Scan
Scans the built image for:
- OS-level CVEs (base image vulnerabilities)
- Language library CVEs (Python packages installed into the image)
- Only blocks on CRITICAL/HIGH **fixable** vulnerabilities (`ignore-unfixed: true`)

#### Step 4: Syft SBOM Generation
```
"Syft is a CLI tool and Go library for generating a Software Bill of
Materials (SBOM) from container images and filesystems." — Anchore
```
Generates two SBOM formats:
- **CycloneDX JSON** — for DefectDojo upload and Cosign attestation
- **SPDX JSON** — for compliance/legal requirements

SBOMs are retained for 365 days as audit evidence.

#### Step 5: Grype SBOM Scan (Second Opinion)
```
"Grype is a vulnerability scanner for container images and filesystems.
Grype works with Syft and can use the generated SBOM for scanning." — Anchore
```
Uses the SBOM (not re-scanning the image) to check vulnerabilities — a second scanner gives confidence and catches CVEs that one scanner might miss.

---

### Stage 8: Build + Push + Sign

Only reaches this stage if all security gates passed.

#### Multi-platform build
```yaml
platforms: linux/amd64,linux/arm64
```
Builds for both Intel and ARM — the image works on Graviton nodes (ARM) for cost savings.

#### Cosign Keyless Signing
```
"Cosign is a tool that supports container signing, verification and
storage in an OCI registry." — Sigstore
```

**Keyless signing** means there's no private key file. Instead:
1. GitHub OIDC token proves "this code ran in GitHub Actions"
2. Fulcio (Sigstore's free CA) issues a short-lived certificate
3. The certificate + signature are recorded in Rekor (public transparency log)
4. Any future `cosign verify` command can cryptographically prove the image was built by this specific CI pipeline

```bash
# How Kyverno verifies at deploy time:
cosign verify \
  --certificate-identity-regexp="github.com/nabilpurkar/intelliops-sherlock" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  <ecr-image>
```

#### SBOM Attestation
The SBOM is attached to the image digest as a signed attestation — tamper-evident. Even if someone replaces the image, the SBOM attestation mismatch would be detectable.

#### SLSA Level 2 Provenance
```
"SLSA (Supply chain Levels for Software Artifacts) is a security
framework to prevent tampering, improve integrity, and secure packages
and infrastructure." — SLSA Working Group
```
Level 2 provenance answers: "Who built this image, from which commit, on which runner, at what time?" — cryptographically signed and verifiable.

---

### Stage 9: Manifest Update

After the image is pushed and signed:
```bash
# Updates k8s/apps/order-service.yaml
image: 123456789.dkr.ecr.us-east-1.amazonaws.com/intelliops-dev/order-service:abc1234
# → becomes:
image: 123456789.dkr.ecr.us-east-1.amazonaws.com/intelliops-dev/order-service:def5678
```

This commit to the platform repo is what ArgoCD watches. The GitOps loop closes here: code change → CI → new image → manifest updated → ArgoCD deploys.

---

### Stage 10: ArgoCD Sync

Optionally triggers ArgoCD to sync immediately rather than waiting for its 3-minute polling interval. Uses the ArgoCD API with a short-lived JWT token:
```bash
argocd app sync order-service --auth-token "${ARGOCD_AUTH_TOKEN}"
```

---

### Stage 11: DAST — Dynamic Application Security Testing (OWASP ZAP)

**What it is:** "OWASP ZAP (Zed Attack Proxy) is the world's most widely used web app scanner. It's a free and open-source tool maintained by a dedicated international team of volunteers." — OWASP

**Two modes:**
- `baseline` (default): Passive-only scan — no requests are modified, no attacks are attempted. Just observes traffic for vulnerabilities like missing security headers.
- `full`: Active scan — ZAP actively probes the application (XSS payloads, SQL injection attempts, IDOR tests).

**Why non-blocking:** DAST runs against the running application (after deployment) — it's informational. If DAST blocked the pipeline, a false positive would mean no deployments until security reviews it.

**What it checks:**
- Missing `X-Content-Type-Options: nosniff` header
- Missing `Content-Security-Policy` header
- CORS misconfiguration
- SQL injection in query parameters
- XSS vulnerabilities
- Information disclosure in error responses

**Results:** Uploaded to DefectDojo and GitHub Security Code Scanning.

---

## DefectDojo — Centralized Security Findings

Every scanner (Semgrep, Trivy, Checkov, ZAP, Dependency-Check) sends results to DefectDojo:

```
DefectDojo = Security findings database
├── Product: IntelliOps Sherlock
├── Engagement: CI Pipeline - Semgrep
│   └── Findings: SQLi pattern in order-service L47
├── Engagement: CI Pipeline - Trivy Image (order-service)
│   └── Findings: CVE-2024-1234 in python:3.12-slim
└── Engagement: DAST - ZAP
    └── Findings: Missing CSP header on /orders endpoint
```

**Why centralize?** Security teams can't monitor 11 different tool dashboards. DefectDojo deduplicates findings across tools, tracks remediation status, and provides compliance metrics.

**UI:** `https://defectdojo.yourdomain.com`

---

## GitHub Code Scanning

All SARIF files are uploaded to GitHub Security → Code Scanning. This means:
- Findings appear inline in pull requests ("this line introduces a vulnerability")
- Security team can dismiss false positives with justification
- Audit trail of every finding and its resolution

---

## Required GitHub Secrets

| Secret | Used By | How to Get |
|--------|---------|------------|
| `SONAR_TOKEN` | SonarQube scan | Generated by configure-stack.sh |
| `DEFECTDOJO_API_KEY` | All scanners | Generated by configure-stack.sh |
| `ARGOCD_AUTH_TOKEN` | ArgoCD sync | Generated by configure-stack.sh |
| `INFRACOST_API_KEY` | Infracost | Register at infracost.io (free) |
| `AWS_ACCOUNT_ID` | Docker build | Your 12-digit AWS account ID |
| `AWS_ROLE_ARN` | Docker build | `intelliops-dev-github-actions-irsa` ARN |

All secrets except `INFRACOST_API_KEY` are automatically set by `./scripts/configure-stack.sh`.

---

## Hands-on Lab: Watch a Full Pipeline Run

```bash
# 1. Make a small change to trigger the pipeline
echo "# test" >> services/order-service/main.py
git add services/order-service/main.py
git commit -m "test: trigger CI pipeline"
git push origin main

# 2. Watch it run
# Go to GitHub → Actions tab → click the running workflow

# 3. Check the Security tab after it completes
# GitHub → Security → Code Scanning → See all SARIF findings

# 4. Check DefectDojo
# https://defectdojo.yourdomain.com → Products → IntelliOps Sherlock

# 5. See the manifest update commit
git log --oneline -5
# You'll see: "ci: update order-service to sha-abc1234"

# 6. Watch ArgoCD deploy
kubectl get pods -n apps -w
# You'll see the rolling update as pods replace with new image
```

---

## Interview Questions — CI/CD Pipeline

**Q1: What's the difference between SAST, SCA, and DAST?**
> *Answer:* "SAST — Static Application Security Testing — analyzes source code without running it. It looks for code patterns like SQL injection or path traversal. We use Semgrep. SCA — Software Composition Analysis — analyzes open-source dependencies for known CVEs. We use Trivy and OWASP Dependency-Check against requirements.txt. DAST — Dynamic Application Security Testing — runs against the live application and sends attack payloads. We use OWASP ZAP. The difference: SAST is early (catches issues in code), SCA catches dependency vulnerabilities, DAST catches issues only visible at runtime like session management bugs."

**Q2: What is Cosign keyless signing and why not use a stored private key?**
> *Answer:* "Keyless signing means there's no key file stored anywhere — not in GitHub Secrets, not in a vault. Instead, we use OIDC: GitHub's token proves this build ran in GitHub Actions, Sigstore's Fulcio CA issues a short-lived certificate for that token, and the signature is recorded in Rekor (a public transparency log). The private key only exists in memory during the signing step and is gone immediately. If you stored a key, it could be leaked from secrets, accessed by a compromised runner, or rotated improperly. With keyless signing, there's nothing to leak."

**Q3: Why do you build the Docker image locally before pushing? Why not push and then scan?**
> *Answer:* "Scan before push is a security requirement: you should never push a potentially vulnerable image to your registry. If an image with a critical CVE lands in ECR, other systems (automated test environments, downstream pipelines) might pull it before you can delete it. Building locally, scanning, then pushing means only clean images reach the registry. The local tag (`scan-<sha>`) never gets pushed — it's only used for scanning."

**Q4: A new CVE is discovered in the Python base image your services use. How does the pipeline handle it?**
> *Answer:* "The next CI run will fail at the Trivy image scan step because Trivy checks the base image OS packages against the NVD/OSV databases. The `--ignore-unfixed: true` flag means it only fails if there's a patch available. If Python releases a patched slim image, we update FROM python:3.12-slim and the scan passes. If there's no patch yet, the flag prevents false positive blocking. For zero-day scenarios, we use Grype as a second scanner — it has its own CVE database and may catch things Trivy misses."

**Q5: How do you prevent a developer from bypassing the CI pipeline and pushing directly to ECR?**
> *Answer:* "Three layers: First, the GitHub Actions OIDC role (`intelliops-dev-github-actions-irsa`) has an IAM trust policy scoped to the main branch of this specific repo — only that branch can assume the role. Second, Kyverno's `verify-image-signatures` policy verifies every pod's image has a valid Cosign signature at admission time — an unsigned image won't start. Third, ECR repository policies can restrict `ecr:PutImage` to only the CI IAM role. So even if a developer has AWS access, they can't push an image that will pass the Kyverno signature check."

**Q6: Why run Checkov for both Terraform and Kubernetes manifests?**
> *Answer:* "Terraform Checkov catches infrastructure misconfigurations at the IaC layer — for example, S3 bucket without versioning, EKS cluster without logging, security groups too permissive. Kubernetes manifest Checkov catches deployment misconfigurations — pods running as root, no resource limits set, privileged containers. Both are blocking because a misconfigured Terraform resource is hard to fix after it's deployed (may require destroy/recreate), and a misconfigured K8s manifest would violate the Kyverno admission policies we enforce at runtime anyway."

---

## What's Next?

→ **[06-platform-tools.md](06-platform-tools.md)** — The platform components that CI/CD deploys into
→ **[08-security-compliance.md](08-security-compliance.md)** — Deep dive on Kyverno, Cosign, and the security policies enforced at runtime
→ **[09-argocd-gitops.md](09-argocd-gitops.md)** — How ArgoCD picks up the manifest updates that CI pushes
