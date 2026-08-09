# kubeadm-on-AWS → EKS - Hub/Spoke Kubernetes Infrastructure

A Terraform + GitHub Actions monorepo that stands up one or more **Amazon
EKS clusters on AWS**, wired together in a **hub/spoke** topology over a
shared Transit Gateway, with **Cilium Cluster Mesh** giving every
cluster's pods a flat, routable address space. The **hub** cluster runs
Argo CD as the fleet's GitOps control plane; **spoke** clusters run
application workloads and register themselves into the hub's Argo CD
automatically.

> **Migration note:** this repo originally ran self-managed **kubeadm
> clusters on EC2** (a master instance bootstrapped via SSM + an
> Auto Scaling Group of workers). It has since been migrated to
> **Amazon EKS with Managed Node Groups**. If you're looking at history or
> old diagrams that mention `modules/ec2`, `modules/asg`, `modules/k8s`,
> `modules/oidc-bucket`, or SSM `send-command` bootstrap jobs - that's the
> pre-migration design. This document describes the **current, post-migration**
> architecture. See "What changed in the EKS migration" below for a
> side-by-side of old vs. new.

If you're new to the repo, read this file top to bottom once, then use the
per-module `README.md` files (`modules/*/README.md`) as reference docs
while you work.

---

## Architecture at a glance

```
                        ┌───────────────────────────┐
                        │   global/network (TGW)     │
                        │  shared Transit Gateway     │
                        │  state: its own root/backend│
                        └──────────────┬─────────────┘
                                       │ transit_gateway_id
                          ┌────────────┴─────────────┐
                          │  (read via terraform_     │
                          │   remote_state, one-way)  │
              ┌───────────▼───────────┐   ┌───────────▼───────────┐
              │       live/hub          │   │      live/spoke        │
              │  EKS control plane      │   │  EKS control plane      │
              │  VPC 10.0.0.0/16       │◄──┤  VPC 10.1.0.0/16       │
              │  runs: Argo CD (GitOps)│TGW│  runs: app workloads   │
              │  Managed Node Group    │   │  Managed Node Group     │
              │  (platform pool)        │   │  + Karpenter (workload) │
              │  own OIDC issuer/IRSA  │   │  own OIDC issuer/IRSA  │
              └────────────────────────┘   └────────────────────────┘
                          │  Cilium Cluster Mesh (ENI IPAM, WireGuard)│
                          └──────────────────── over the same TGW ──────────┘
```

* **`global/network`** - a shared Transit Gateway (TGW), applied once,
  independently, before hub or spoke.
* **`live/hub`** - one EKS cluster whose main job is to run **Argo CD**,
  the GitOps controller for the whole fleet.
* **`live/spoke`** - one EKS cluster that runs actual application
  workloads. Additional spokes are added by copying this root (e.g.
  `live/spoke-2`) - see "Adding a second spoke" below.
* Hub and spoke VPCs are connected through the shared TGW so the hub's
  Argo CD can reach each spoke's `kube-apiserver` directly (pull-based
  GitOps against every registered cluster), and so cross-cluster pod
  traffic (Cluster Mesh) can be natively routed.
* Each cluster uses its **own EKS-hosted OIDC issuer** (`modules/irsa`) for
  IRSA, so a pod identity from one cluster can never validate against
  another cluster's provider.

Both `live/hub` and `live/spoke` are structurally near-identical roots
(vpc → tgw-attachment → eks → eks-node-role → eks-node-group → irsa →
s3/none), differing mainly in a handful of flags
(`enable_karpenter_discovery`, whether S3 buckets or a Karpenter IRSA role
exist, `install_cni_ccm`).

**Ingress note:** `modules/alb` and `modules/acm` exist in this repo but
**neither `live/hub` nor `live/spoke` currently instantiates them** - no
`module "alb"` / `module "acm"` block exists in either root's `main.tf`.
Treat those two modules as reserved/legacy for now. Application ingress
today happens inside the cluster (NGINX Ingress / Gateway API via Argo CD,
forwarding to a CCM-provisioned NLB), there is no other Terraform-managed
internet-facing load balancer at the moment.

---

## What changed in the EKS migration

| Area | Before (kubeadm on EC2) | Now (EKS) |
|---|---|---|
| **Control plane** | Self-managed on a master EC2 instance, bootstrapped with `kubeadm init` via SSM `send-command` | Managed by AWS (`aws_eks_cluster`, `modules/eks`) - no master instance at all |
| **Worker nodes** | `modules/asg` Launch Template + Auto Scaling Group, `kubeadm join` at boot | `modules/eks-node-group` Managed Node Group (`aws_eks_node_group`) for the baseline "platform" pool |
| **Node IAM auth** | Broad node instance-profile roles | EKS **access entries** (`aws_eks_access_entry`) authorize a node role to join - see `modules/eks-node-role` |
| **AMI** | Custom Packer-baked `k8s-base` AMI (`modules/ami`, `/packer`) with containerd/kubeadm/kubelet baked in | EKS-optimized AMI, selected via `ami_type` on the node group (no more Packer pipeline for nodes) |
| **OIDC / IRSA issuer** | Self-hosted: kube-apiserver's own issuer, discovery doc + JWKS hand-published to a public-read S3 bucket (`modules/oidc-bucket`) | EKS's **built-in OIDC endpoint** (`module.eks.cluster_oidc_issuer_url`) - no bucket, no self-publish step |
| **Cluster access** | `aws ssm start-session` to the master; kubectl over an SSM tunnel or VPC-internal SSH | Direct: `aws eks update-kubeconfig` + kubectl/helm against the API server (gated by IAM + access entries) |
| **CI → cluster auth** | SSM `send-command` dispatch, IAM scoped to SSM actions | `aws_eks_access_entry` + `AmazonEKSAdminPolicy` granted to a GitHub OIDC-federated IAM role (`argocd_registration_ci`) |
| **Bring-up sequencing** | `kubeadm init` (CI/SSM) → CNI/CCM inline in `master_init.sh.tpl` → Argo CD install | `terraform apply` (control plane + node group) → Cilium/CCM installed imperatively via CI (hub only) → Argo CD install |
| **Karpenter placement** | Ran on the master (to avoid a self-termination race) | Runs on the platform Managed Node Group (spoke only) |
| **Teardown** | PVC/LB/Karpenter drain scripts run over SSM against the master | Same drain scripts, run directly against the cluster via `aws eks update-kubeconfig` (no SSM dependency) |
| **Modules removed** | `modules/ec2`, `modules/asg`, `modules/k8s`, `modules/oidc-bucket` | Replaced by `modules/eks`, `modules/eks-node-role`, `modules/eks-node-group` |
| **Modules added** | - | `modules/eks`, `modules/eks-node-role`, `modules/eks-node-group` |
| **Modules unchanged** | `modules/vpc`, `modules/tgw-attachment`, `modules/irsa`, `modules/s3`, `modules/ami` (now legacy, unused by `live/*`), `modules/alb`, `modules/acm` (still unwired) |

The GitOps registration flow (spoke pushes a token to Secrets Manager →
ESO on the hub materializes a cluster Secret → Argo CD adopts it) is
**functionally unchanged** - only the transport for CI-to-cluster commands
changed, from SSM to direct kubectl/helm against the EKS API.

---

## Repo layout

```
global/network/          Shared Transit Gateway
live/hub/                Hub cluster root module (EKS + Argo CD)
live/spoke/              Spoke cluster root module (EKS + app workloads)
modules/                 Reusable Terraform modules (see table below)
.github/workflows/       CI (lint/validate) + CD (deploy/destroy) pipelines
.github/scripts/         Shell script templates run against clusters (drain, deregister, bootstrap)
.github/actions/         Shared composite actions (eks-connect, etc.)
```

### Terraform modules

| Module | Purpose | Wired into `live/*` today? |
|---|---|---|
| [`vpc`](modules/vpc/README.md) | VPC, public/private subnets, a NAT Gateway, S3 gateway endpoint, SSM interface endpoints, optional `karpenter.sh/discovery` subnet tagging | Yes |
| [`eks`](modules/eks) | EKS control plane, cluster IAM role, additional control-plane security group, CoreDNS addon, OIDC issuer output | Yes |
| [`eks-node-role`](modules/eks-node-role) | IAM role for a node pool (worker node policy, ECR read-only, SSM). Split out from `eks-node-group` so its EKS access entry can exist before nodes try to join | Yes |
| [`eks-node-group`](modules/eks-node-group) | Managed Node Group (baseline "platform" pool: ArgoCD, cilium-operator, coredns, cert-manager, external-secrets, etc.) | Yes |
| [`irsa`](modules/irsa/README.md) | Registers this cluster's (now EKS-hosted) OIDC issuer with AWS and creates one trust-scoped IAM role per ServiceAccount | Yes |
| [`tgw-attachment`](modules/tgw-attachment) | Attaches a cluster's VPC to the shared TGW and adds peer routes | Yes |
| [`s3`](modules/s3/README.md) | Application/cluster S3 buckets (Loki/Tempo on the hub) | Hub only |
| [`ami`](modules/ami/README.md) | Looks up the newest Packer-built base AMI | **Legacy** - not referenced by `live/*` post-migration; kept for reference/rollback |
| [`alb`](modules/alb) | Internet-facing ALB, per-app target groups, host-based HTTPS routing | **Not instantiated** - present but unused |
| [`acm`](modules/acm/README.md) | ACM certificate for an ALB's HTTPS listener | **Not instantiated** - present but unused |

---

## Node bring-up: what runs where

| Layer | What it does | When it runs | Where it lives |
|---|---|---|---|
| **Terraform (`modules/eks`)** | Creates the EKS control plane, CoreDNS addon | On `terraform apply` | `modules/eks/main.tf` |
| **Terraform (`modules/eks-node-role` + `eks-node-group`)** | Node IAM role, EKS access entry, Managed Node Group | On `terraform apply`, in that order (role → access entry → node group, via explicit `depends_on`) | `live/hub/main.tf`, `live/spoke/main.tf` |
| **CI (`k8s-cluster-bootstrap.yml`)** | Hub: installs Cilium (hostNetwork DaemonSet, schedules even on a `NotReady`/no-CNI node) + AWS CCM imperatively via Helm, waits for the `uninitialized` taint to clear. Spoke: just verifies the apiserver is reachable - the hub's Argo CD installs Cilium/CCM on spokes after registration | Right after `terraform apply` | `.github/workflows/k8s-cluster-bootstrap.yml` |
| **Argo CD (GitOps)** | Everything else: CCM/Cilium upgrades on spokes, External Secrets Operator, application workloads, Cluster Mesh CA distribution | Continuously, reconciling from Git | separate `gitops` repo (referenced by raw URL) |

Why Cilium has to be installed imperatively on the hub first: Argo CD's own
pods need real pod networking to schedule, but pod networking is normally
installed *by* Argo CD (Cilium as an Argo CD Application) - so on the hub,
Cilium + CCM are installed via CI first, nodes are waited on to reach
`Ready`, and only then does Argo CD "adopt" them as Applications it
continues to reconcile.

---

## IAM model: IRSA, EKS access entries, no more node-role-does-everything

Two distinct AWS-IAM mechanisms are in play, and it's worth keeping them
separate:

1. **EKS access entries** (`aws_eks_access_entry` /
   `aws_eks_access_policy_association`) - authorize a *principal* (a node
   IAM role, or a human/CI IAM role) to talk to the Kubernetes API at all,
   replacing the old `aws-auth` ConfigMap model. Every node role and the
   CI role (`argocd_registration_ci`) needs one of these.
2. **IRSA** (`modules/irsa`) - authorizes a *specific pod's ServiceAccount*
   (via `sts:AssumeRoleWithWebIdentity` against the cluster's own OIDC
   issuer) to call AWS APIs directly, independent of which node it landed
   on. Used by Cilium's ENI operator, AWS CCM, the EBS CSI driver, External
   Secrets Operator, Karpenter, and (hub only) Loki/Tempo.

Each cluster:
1. Registers its own OIDC issuer with AWS - now for free via
   `module.eks.cluster_oidc_issuer_url`, no self-hosted discovery bucket.
2. Creates one narrowly-scoped `aws_iam_role` per workload, trusted only
   for `system:serviceaccount:<namespace>:<name>` (`live/*/main.tf`'s
   `roles = { ... }` maps).
3. Injects the role ARN via ServiceAccount annotation - EKS's control
   plane runs its own IRSA mutating webhook unconditionally, so every role
   (including Cilium/CCM on the hub, which used to need special day-0
   env-var injection) is just a normal annotation from wave 0 onward.

See `modules/irsa/README.md` for the full mechanic and how to onboard a
new workload.

---

## Cluster Mesh (cross-cluster pod networking)

Unchanged by the EKS migration. Cilium runs in **ENI IPAM mode**
(`ipam.mode=eni`) - pods get real VPC IPs out of the cluster's own subnets
via ENI secondary IPs / prefix delegation. Cross-cluster pod reachability
relies on:

* Every cluster's VPC attached to the shared TGW (`modules/tgw-attachment`)
  with routes toward every peer cluster's VPC CIDR.
* `routingMode=native` / `autoDirectNodeRoutes=false`, with
  `kubeProxyReplacement=true` and NodePort range `30000-32767`.
* WireGuard encryption (`cilium_wg0`, UDP/51871) between real node IPs.
* `clustermesh-apiserver` exposed on a fixed NodePort, reachable from any
  cluster in the fleet's VPC-CIDR supernet.
* The Cluster Mesh CA pushed by the hub / pulled by each spoke via External
  Secrets Operator, authenticated through the `external-secrets` IRSA role
  on each cluster.

`live/hub/main.tf` and `live/spoke/main.tf` each run a `check` block
asserting all relevant VPC CIDRs are disjoint, so a bad CIDR fails at
`terraform plan` instead of deep inside a TGW route apply.

---

## Karpenter (spoke node autoscaling)

Spokes run **Karpenter on the platform Managed Node Group** (the stable
pool it doesn't itself manage - same reasoning as the old kubeadm design's
"Karpenter on the master": avoid the controller terminating its own node
mid-drain), alongside the ASG-replaced-by-MNG baseline pool. Karpenter has
its own IRSA role scoped to fleet discovery/provisioning/termination for
this cluster, and its own node IAM role + EKS access entry
(`modules/eks-node-role`) - Karpenter creates and owns the instance profile
itself from that role's name (`EC2NodeClass.spec.role`), unlike the
kubeadm-era version which needed `iam:PassRole` onto a Terraform-managed
worker instance profile. The hub does **not** run Karpenter
(`enable_karpenter_discovery = false`).

Because Karpenter-provisioned instances aren't Terraform-managed, teardown
has a dedicated step - see `.github/scripts/drain-karpenter-nodes.sh.tpl`
and the `has_karpenter` input on `drain-cluster.yml` - to deprovision them
via the Kubernetes API before `terraform destroy` runs, with a direct
EC2-termination fallback if the controller is unresponsive.

---

## Access model

There is no master instance and no SSM tunnel anymore. Cluster access is
direct:

```bash
aws eks update-kubeconfig --name <cluster_name> --region ap-northeast-1
kubectl get nodes
```

This works because the caller's IAM principal holds an EKS **access
entry** on the target cluster - either the identity that ran
`terraform apply` (implicit cluster-admin via
`bootstrap_cluster_creator_admin_permissions = true`), or the CI role
(`argocd_registration_ci`, granted `AmazonEKSAdminPolicy` via
`aws_eks_access_policy_association`). See
`.github/actions/eks-connect/action.yml`.

`modules/vpc` still provisions the SSM interface VPC endpoints for
debugging parity (worker nodes retain `AmazonSSMManagedInstanceCore`), but
it is no longer the primary or only access path.

---

## How a spoke joins the hub's Argo CD (GitOps registration)

1. **Terraform (`live/spoke`)** provisions the EKS cluster; the CI role is
   granted permission to write only to `argocd-clusters/<cluster_name>-*`
   in Secrets Manager.
2. **CI (`k8s-register-with-hub.yml`)** connects kubectl directly to the
   spoke (`aws eks update-kubeconfig`), creates an `argocd-manager` service
   account with `cluster-admin`, mints a token, and pushes
   `{name, role, server, token, caData}` to Secrets Manager. Token rotation
   now runs as a **scheduled GitHub Actions job** rather than a systemd
   timer on a host that no longer exists.
3. **On the hub**, External Secrets Operator (its own IRSA role) reads that
   path and materializes a Kubernetes `Secret` labeled
   `argocd.argoproj.io/secret-type=cluster,cluster-name=<name>`.
4. Argo CD sees the labeled Secret and treats the spoke as registered - no
   `argocd cluster add` step.
5. **CI (`verify-spoke-registration.yml`)** connects to the hub the same
   way and polls for that Secret, failing loudly with a checklist of likely
   causes on timeout.

Registering a cluster with Argo CD itself is still a **GitOps fact**: add
`argocd/clusters/<name>.yaml` to the separate `gitops` repo once; the
`root-clusters` Application (selfHeal) reconciles the `ExternalSecret` for
every registered cluster from there.

---

## Apply order (first-time bring-up)

```
1. global/network   (shared TGW - must exist before hub or spoke)
2. live/hub         (terraform apply → Cilium/CCM install → Argo CD install)
3. live/spoke       (terraform apply → apiserver check → register with hub → verify)
```

Use **`deploy-all.yml`** to run a first-time bring-up: it chains
`deploy-network` → `{deploy-hub, deploy-spoke-infra}` in parallel →
`verify-spoke-registration`. Hub and spoke can run in parallel because
spoke's Terraform state has no dependency on hub's; only the final
registration check needs both to have finished.

| Workflow | Scope |
|---|---|
| `deploy-network.yml` | `global/network` only - rare, e.g. changing `amazon_side_asn` |
| `deploy-hub.yml` | `live/hub` terraform apply → `k8s-cluster-bootstrap.yml` (Cilium/CCM) → `k8s-bootstrap-argocd.yml` (Argo CD install) |
| `deploy-spoke-infra.yml` | `live/spoke` (or any `spoke_dir`) terraform apply → `k8s-cluster-bootstrap.yml` (apiserver check) → `k8s-register-with-hub.yml`. Stops short of verifying the hub picked up the registration |
| `deploy-spoke.yml` | `deploy-spoke-infra.yml` + `verify-spoke-registration.yml` - the full single-spoke chain for a day-2 change |
| `deploy-all.yml` | First-time bring-up only: `deploy-network` → `{deploy-hub, deploy-spoke-infra}` (parallel) → `verify-spoke-registration` |

For any day-2 change to a single cluster, use the narrower workflow instead
of `deploy-all.yml` - it won't force an unrelated cluster's bootstrap/Argo
CD steps to re-run.

### Adding a second spoke later

1. Copy `live/spoke` → `live/spoke-2` (new backend key, new `vpc_cidr`
   disjoint from every other cluster, new `envs/<env>/terraform.tfvars`).
2. Add its CIDR to `live/hub`'s `spoke_vpc_cidrs` and re-apply the hub
   (needed for the TGW route + apiserver trust,
   `trusted_api_cidr_blocks`).
3. Run `deploy-spoke.yml` (or `deploy-all.yml`'s pattern) with
   `spoke_dir: live/spoke-2`.

---

## Teardown order

```
1. deregister-from-argocd  (spoke only - must run while the hub cluster is
                             still alive, before either cluster is drained)
2. drain-spoke + drain-hub                    (parallel)
3. terraform-destroy-spoke + terraform-destroy-hub   (parallel)
4. global/network                              (last - hub/spoke state
                                                 both read its TGW id)
```

`drain-cluster.yml` (used for both hub and spoke) connects directly via
`aws eks update-kubeconfig` (no SSM "is the master reachable" check
anymore - instead it checks whether the EKS cluster exists and
`/readyz` responds), then runs, in order: optional local Argo CD freeze
(hub only) → LoadBalancer Service drain → PVC drain (namespace-cascade) →
**Karpenter node drain** (spoke only) - Karpenter must run last since the
earlier steps still need live worker nodes.

| Workflow | Scope |
|---|---|
| `k8s-deregister-from-hub.yml` | Spoke only - temporarily removes the spoke from ArgoCD's live inventory so nothing can resurrect a workload while draining runs. Not tolerant of failure |
| `drain-cluster.yml` | Load-balancer drain → PVC drain → Karpenter node drain (spoke only), before that cluster's infra is torn down. Best-effort |
| `terraform-destroy-hub.yml` / `terraform-destroy-spoke.yml` | `terraform destroy` for that root only |
| `destroy-hub.yml` | `drain-cluster` → `terraform-destroy-hub`, hub only |
| `destroy-spoke.yml` | `k8s-deregister-from-hub` → `drain-cluster` → `terraform-destroy-spoke`, one spoke only |
| `destroy-all.yml` | Full environment teardown |
| `destroy-network.yml` | `global/network` - run last |

Karpenter-managed nodes are not Terraform-managed at all - undrained, they
can make `terraform destroy` fail outright on VPC/security-group deletion,
not just leak cost.

---

## State & backend

All roots use an **S3 backend** with **S3 native locking**
(`use_lockfile = true` - no DynamoDB table required), bucket
`terraform-phuoctd6`, region `ap-northeast-1`. Each root's `key` is
supplied at `terraform init` time via `-backend-config=envs/<env>/backend.hcl`
so `backend.tf` itself stays identical across environments:

| Root | State key |
|---|---|
| `global/network` | `global/network/<env>/terraform.tfstate` |
| `live/hub` | `hub/<env>/terraform.tfstate` |
| `live/spoke` | `spoke/<env>/terraform.tfstate` |

`live/hub` and `live/spoke` each read `global/network`'s state via
`terraform_remote_state` (one-directional) for `transit_gateway_id`.

---

## CI checks (`terraform.yml`, on every PR touching `.tf`/`.tfvars`, and on every push)

* `terraform fmt -check`
* `terraform validate` (matrix: `global/network`, `live/hub`, `live/spoke`; `init -backend=false`, no real credentials needed)
* `tflint` (matrix, same three roots - see `.tflint.hcl` for enabled rules)
* `trivy` config scan across the whole repo

---

## Security notes worth knowing

* Node/cluster access is governed by **EKS access entries**, not the old
  `aws-auth` ConfigMap - a node or CI role with no access entry simply
  cannot talk to the API, IAM policy alone is not sufficient.
* Most controller AWS permissions are IRSA roles scoped to one
  ServiceAccount each - node roles carry only baseline worker/ECR/SSM
  policies.
* The public-endpoint CIDR allowlist (`public_access_cidrs` on
  `modules/eks`) currently defaults wide open to let GitHub-hosted runners
  reach the API server directly - tighten this (or move to self-hosted
  runners inside the VPC) once you've settled on a trust model for CI.
* Cluster Mesh CA IAM access is scoped to the `clustermesh/*` Secrets
  Manager prefix on the `external-secrets` IRSA role, separate from
  `argocd-clusters/*`.
* `.tflint.hcl` deliberately disables `terraform_module_pinned_source` -
  every module source is a local path in this monorepo.

---

## Where to look next

* Each module has its own `README.md` with resource tables, variable
  references, and design rationale - read the module's README before
  changing its `main.tf`.
* `.github/workflows/` - each workflow file's header comment explains why
  it's split the way it is (parallelism, race-freedom on teardown, the
  specific EKS-vs-kubeadm rewrite it went through); the tables above
  summarize but the in-file comments are the source of truth for edge
  cases.
* `modules/irsa/README.md` explains the IRSA mechanic and how to onboard a
  new workload onto it.
* If you need to compare against the pre-migration design, `modules/ami`
  and its README describe the old Packer-baked AMI pipeline, kept for
  reference even though `live/*` no longer references it.