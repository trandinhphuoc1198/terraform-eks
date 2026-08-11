# Hub-Spoke Kubernetes on AWS (EKS + Terraform + ArgoCD)

Terraform infrastructure and GitHub Actions CI/CD for a **multi-cluster, hub-spoke Kubernetes platform** on AWS EKS. One "hub" cluster runs the fleet's ArgoCD; one or more "spoke" clusters run workloads and self-register into the hub's ArgoCD via GitOps. All clusters share a single Transit Gateway and form a Cilium Cluster Mesh across VPCs.

> **Note on history:** this repo was migrated from a self-managed **kubeadm-on-EC2** design (SSM `send-command`, a persistent master instance, Packer-baked AMIs) to **managed EKS** (IAM/OIDC, direct `kubectl`/`helm` from CI runners). Several scripts and modules still carry comments describing the old design — see [Legacy / orphaned pieces](#legacy--orphaned-pieces).

---

## 1. Architecture

```
                        ┌─────────────────────────┐
                        │   global/network          │
                        │   Transit Gateway (TGW)    │
                        │   (own state - apply first,│
                        │    destroy last)           │
                        └──────────┬──────────┬──────┘
                                   │          │
                    TGW attachment │          │ TGW attachment
                                   │          │
                 ┌─────────────────▼───┐  ┌───▼─────────────────┐
                 │ live/hub (EKS)       │  │ live/spoke (EKS)     │
                 │ 10.0.0.0/16          │  │ 10.1.0.0/16          │
                 │                      │  │                      │
                 │ • ArgoCD             │◄─┼─ registers via ESO   │
                 │ • Loki / Tempo (S3)  │  │ • Karpenter (workload│
                 │ • platform node grp  │  │   node pool)         │
                 │ • Cilium + AWS CCM   │  │ • platform node grp  │
                 │   (Terraform-bootst, │  │ • Cilium + AWS CCM   │
                 │    ArgoCD-adopted)   │  │   (same pattern)     │
                 └──────────────────────┘  └──────────────────────┘
                       Cilium Cluster Mesh over TGW (WireGuard)
```

**State layout** — three independent Terraform roots, one S3 backend bucket, distinct keys:

| Root | State key | Purpose |
|---|---|---|
| `global/network` | `global/network/<env>/terraform.tfstate` | Shared Transit Gateway. Apply first, destroy last — both `live/hub` and `live/spoke` read its `transit_gateway_id` via `terraform_remote_state`. |
| `live/hub` | `hub/<env>/terraform.tfstate` | Hub EKS cluster, ArgoCD host, Loki/Tempo S3 buckets, IRSA roles, CI IAM role. |
| `live/spoke` | `spoke/<env>/terraform.tfstate` | Spoke EKS cluster, Karpenter workload pool, IRSA roles, CI IAM role. `spoke_dir` input lets the same code drive additional spokes (`live/spoke-2`, ...) without duplicating modules. |

Backend config (`envs/<env>/backend.hcl`) supplies only the `key`; bucket/region/lockfile settings live in each root's `backend.tf` and are identical across environments — this is what lets `terraform init -backend-config=envs/<env>/backend.hcl` work uniformly in CI.

### Networking
- Each cluster gets its own VPC (`modules/vpc`): public + private subnets across 2 AZs, NAT Gateway, S3 Gateway endpoint, SSM Interface endpoints (for node debugging even without a persistent master).
- **CIDR overlap is enforced at plan time** — both `live/hub/main.tf` and `live/spoke/main.tf` have a `check` block that fails the plan if any two cluster CIDRs overlap (would break TGW routing).
- `modules/tgw-attachment` attaches each VPC to the shared TGW and adds routes to the peer cluster's CIDR(s) in that VPC's own route tables. The TGW's own route-table association/propagation is owned centrally by `global/network`, not by hub or spoke.

### Kubernetes / EKS
- `modules/eks` provisions the control plane with **API-only authentication mode** (`access_config.authentication_mode = "API"`) — no aws-auth ConfigMap, everything is `aws_eks_access_entry` / `aws_eks_access_policy_association`.
- **Node join ordering matters and is enforced by an explicit dependency graph**, not just data flow: `eks-node-role` (IAM role) → `aws_eks_access_entry` → `eks-node-group`, with the node group's `depends_on` pointing at the access entry. Without this, a node group can apply before its access entry exists and instances come up stuck `NotReady` with no obvious error.
- **CNI bootstrap breaks the chicken-and-egg problem**: `helm_release.cilium` (chart defaults, `wait = false`) is installed via Terraform *before* the node group exists, so nodes can actually go `Ready`. ArgoCD later reconciles the **same release name/namespace** with the fleet's real values from the separate GitOps repo — a takeover, not a second install. Terraform's `lifecycle.ignore_changes = [values, set, set_sensitive]` stops it from fighting ArgoCD's drift correction afterward. AWS Cloud Controller Manager follows the same bootstrap-then-adopt pattern.
- CoreDNS is installed as a first-class `aws_eks_addon`, explicitly `depends_on` the node group (not just the cluster) — this fixes an earlier bug where it raced the node group in parallel, both blocked on the missing CNI.
- **IRSA** (`modules/irsa`): one `aws_iam_openid_connect_provider` per cluster (each kubeadm/EKS cluster has its own signing key → its own issuer, never shared), plus one narrowly-scoped IAM role per `{namespace, service_account}` pair. Current role map:
  - Hub: `ebs-csi-controller`, `external-secrets`, `loki`, `tempo`, `cloud-controller-manager`, `cilium-operator`
  - Spoke: `ebs-csi-controller`, `external-secrets`, `aws-cloud-controller-manager`, `cilium-operator`, `karpenter`

### GitOps / ArgoCD registration
ArgoCD lives **only on the hub**. Spokes register through Secrets Manager + External Secrets Operator, not a CI-side `kubectl apply`:

1. CI (`k8s-register-with-hub.yml`) creates an `argocd-manager` ServiceAccount + `cluster-admin` ClusterRoleBinding on the spoke, mints a token, and pushes `{name, role, server, token, caData}` to Secrets Manager at `argocd-clusters/<cluster_name>`.
2. In the separate **GitOps repo**, `argocd/clusters/<name>.yaml` (an `ExternalSecret`) is added once, by hand, per new spoke.
3. ESO on the hub materializes that into a `Secret` labeled `argocd.argoproj.io/secret-type=cluster` — ArgoCD's native cluster-registration mechanism.
4. `root-clusters` (an ArgoCD `Application`, `selfHeal: true`) watches `argocd/clusters/*.yaml` and keeps the ExternalSecret in sync with git.
5. `spokes/` ApplicationSets use ArgoCD's cluster generator to fan out Applications onto every registered cluster.
6. `verify-spoke-registration.yml` polls for that labeled Secret to confirm the whole chain completed before declaring a deploy successful.

Token rotation used to be a `systemd` timer on the kubeadm master (`register-with-hub.sh.tpl`'s `ROTATE` heredoc); with no persistent host under EKS, `k8s-register-with-hub.yml` is instead triggered on a **GitHub Actions schedule** — same effect, different execution environment, but now depends on a scheduled workflow holding standing AWS credentials.

---

## 2. Repository layout

```
global/network/          Shared Transit Gateway (own state)
live/hub/                 Hub EKS cluster root module
live/spoke/                Spoke EKS cluster root module (spoke_dir lets this be reused for spoke-2, ...)
modules/
  vpc/                     VPC, subnets, NAT, S3/SSM endpoints, route tables
  eks/                     EKS control plane, cluster SGs, Cluster Mesh SG
  eks-node-role/           IAM role for a node pool (split from node group - see access-entry ordering note)
  eks-node-group/          Managed Node Group + launch template
  tgw-attachment/          VPC↔TGW attachment + peer-CIDR routes
  irsa/                    Per-ServiceAccount IAM roles via OIDC federation
  s3/                      General-purpose S3 buckets (Loki/Tempo on hub)
  acm/                     ACM cert + Route53 DNS validation (currently unused - no ALB provisioned yet)
  ami/                     Packer AMI lookup (legacy - kubeadm era, unused under EKS)
.github/
  workflows/               All CI/CD pipelines (see below)
  scripts/                 *.sh.tpl scripts, rendered via sed and run by CI or (originally) SSM
  actions/eks-connect/     Composite action: aws eks update-kubeconfig + readiness check
.tflint.hcl                Lint rules (local module sources intentionally unpinned - monorepo)
```

---

## 3. CI/CD

### Validation (`terraform.yml`, on every PR touching `*.tf`/`*.tfvars`/`*.pkr.hcl`, and every push)
- `terraform fmt -check -diff`
- `terraform validate` — matrix over `[global/network, live/hub, live/spoke]`, `-backend=false` (no real credentials needed)
- `tflint` — same matrix, uses `.tflint.hcl` (AWS ruleset; naming convention, unused declarations, typed variables enforced; module-source-pinning and output-doc rules deliberately off)
- `trivy` config scan (whole repo)

### Deploy path
All roots funnel through one reusable workflow, **`terraform-apply.yml`**: OIDC AWS auth → `terraform init -backend-config=envs/<env>/backend.hcl` → `plan [-destroy] [-var-file] [extra -var flags]` → `apply` → optional `terraform output -raw <name>` capture. GitHub `environment:` (dev/prod) is applied at this shared workflow's job level, which is how deployment-protection rules (required reviewers, etc.) end up enforced uniformly regardless of which root calls it.

| Workflow | Scope | Notes |
|---|---|---|
| `deploy-network.yml` | `global/network` | Rare — only on TGW config changes or first bring-up |
| `deploy-hub.yml` | `live/hub` | apply → wait for nodes Ready → install ArgoCD (idempotent) |
| `deploy-spoke-infra.yml` | one spoke | apply → verify apiserver reachable → push registration token |
| `deploy-spoke.yml` | one spoke | `deploy-spoke-infra` + `verify-spoke-registration` chained, for a full day-2 spoke change |
| `deploy-all.yml` | everything | **first bring-up only**: network → {hub, spoke-infra} in parallel → spoke-register. Hub and spoke can run in parallel because spoke's state has no `terraform_remote_state` dependency on hub's (`hub_vpc_cidr` is a plain tfvar) |

### Teardown path
Mirrors deploy, but with extra care around two races:

| Workflow | Scope | Notes |
|---|---|---|
| `k8s-deregister-from-hub.yml` | one spoke | **Must run before any drain.** Deletes `root-clusters` (`cascade=orphan`) first so ArgoCD's own selfHeal can't resurrect what's deleted next; then the spoke's ExternalSecret/Secret; then its generated Applications in reverse sync-wave order (discovered dynamically from `argocd.argoproj.io/sync-wave` annotations, no hardcoded release list). Node-critical infra (cilium, ebs-csi, ccm, karpenter) is deliberately excluded — deleted later, after PVC drain. **Fails loudly** on any unconfirmed step; this is the one phase the rest of the pipeline is *not* best-effort about. |
| `drain-cluster.yml` | one cluster | Freezes local ArgoCD controllers (hub only), deletes `type=LoadBalancer` Services (handles Gateway-API-owned Services + Classic ELB fallback, waits for the real AWS-side deletion, not just the K8s object), drains PVCs (**deletes the owning namespace, not the PVC** — a bare `kubectl delete pvc` leaves the `pvc-protection` finalizer stuck forever while a live pod holds it), then (spoke only) deprovisions Karpenter NodeClaims with a direct-EC2-terminate fallback. Best-effort throughout — a stuck resource logs a `::warning::`, never fails the job. |
| `terraform-destroy-hub.yml` / `terraform-destroy-spoke.yml` | one root | `terraform-apply.yml` with `destroy: true` |
| `destroy-hub.yml` / `destroy-spoke.yml` | one cluster | Standalone chains of the two workflows above, for tearing down a single cluster without touching the rest |
| `destroy-network.yml` | TGW | **Must run last** — both live roots read its state via `terraform_remote_state`; destroying it first breaks their `plan`/`destroy` |
| `destroy-all.yml` | everything | deregister → {drain-spoke, drain-hub} parallel → {terraform-destroy-spoke, terraform-destroy-hub} parallel → network last |

### Cluster access model
No SSM, no bastion, no persistent master. `.github/actions/eks-connect` runs `aws eks update-kubeconfig` and checks `/readyz`; every workflow that needs `kubectl`/`helm` authenticates via an OIDC-federated IAM role (`argocd_registration_ci` per cluster) that holds an **EKS access entry** with `AmazonEKSAdminPolicy`. IAM policy alone is not sufficient under API auth mode — the access entry is what actually grants in-cluster RBAC.

---

## 4. Operational gotchas worth knowing before you touch this repo

- **CIDRs must stay disjoint.** Adding a new spoke means picking a `vpc_cidr` that doesn't overlap the hub or any existing spoke — enforced by a `check` block that fails `plan`, not just `apply`.
- **`spoke_vpc_cidrs` on the hub is a static list, not derived.** It's populated by hand to avoid a circular `terraform_remote_state` dependency between hub and spoke. Add an entry per new spoke.
- **Destroy order is not arbitrary.** Spoke and hub can be destroyed in either order relative to each other, but `global/network` must always be last, and per-cluster ArgoCD deregistration must always happen before that cluster's PVC drain.
- **`public_access_cidrs` defaults to `0.0.0.0/0`** on both clusters' EKS API servers, to let GitHub-hosted runners reach them directly. This is called out in `modules/eks/variables.tf` as something to tighten once you've decided between an IAM-only trust model and a self-hosted runner inside the VPC.
- **The scheduled token-rotation workflow holds standing AWS credentials on a cron trigger** — a deliberate tradeoff replacing the old host-level systemd timer, called out directly in `k8s-register-with-hub.yml`'s header.
- **Two modules are currently unused** in `live/hub`/`live/spoke`: `modules/acm` (no ALB is provisioned by any root today) and `modules/ami` (EKS node groups resolve their AMI via `ami_type`, not a Packer-baked custom image). Keep them if there's a near-term plan to add an ALB / revert to custom AMIs; otherwise they're candidates for removal or an explicit "reserved" note.

---

## 5. Adding a second spoke

1. Add a CIDR to `live/hub/envs/<env>/terraform.tfvars`'s `spoke_vpc_cidrs`, apply hub.
2. Create `live/spoke-2/` (copy `live/spoke/`, new `terraform.tfvars` with a disjoint `vpc_cidr` and matching `hub_vpc_cidr`).
3. Run `deploy-spoke.yml` (or `deploy-spoke-infra.yml` + `verify-spoke-registration.yml`) with `spoke_dir: live/spoke-2`.
4. Add `argocd/clusters/<new-cluster-name>.yaml` to the GitOps repo so ESO/root-clusters picks it up.

No new workflow files are needed — `spoke_dir` is threaded through every spoke-facing workflow for exactly this reason.