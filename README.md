# Hub/Spoke Kubernetes on AWS EKS

Terraform + GitHub Actions monorepo that stands up one or more **Amazon EKS
clusters**, wired into a **hub/spoke** topology over a shared Transit
Gateway, with **Cilium Cluster Mesh** giving every cluster's pods a flat,
routable address space. The **hub** cluster runs Argo CD as the fleet's
GitOps control plane; **spoke** clusters run application workloads and
register themselves into the hub's Argo CD automatically.

> **Migration note:** this repo originally ran self-managed **kubeadm
> clusters on EC2** (a master instance bootstrapped via SSM `send-command`
> + an Auto Scaling Group of workers). It has since been migrated to
> **EKS + Managed Node Groups**. Anything referencing `modules/ec2`,
> `modules/asg`, `modules/k8s`, `modules/oidc-bucket`, or SSM bootstrap is
> the pre-migration design - see [What changed](#what-changed-in-the-eks-migration)
> for the side-by-side. A couple of pre-migration leftovers are still
> physically present in the repo; see [Known drift](#known-drift--things-worth-cleaning-up).

---

## Architecture at a glance

```
                        ┌───────────────────────────┐
                        │   global/network (TGW)     │
                        │  shared Transit Gateway     │
                        │  own state/backend           │
                        └──────────────┬─────────────┘
                                       │ transit_gateway_id
                          ┌────────────┴─────────────┐
                          │ read one-way via           │
                          │ terraform_remote_state     │
              ┌───────────▼───────────┐   ┌───────────▼───────────┐
              │        live/hub          │   │       live/spoke        │
              │  EKS control plane      │   │  EKS control plane      │
              │  VPC 10.0.0.0/16       │◄──┤  VPC 10.1.0.0/16       │
              │  runs: Argo CD (GitOps)│TGW│  runs: app workloads   │
              │  MNG "platform" pool    │   │  MNG "platform" +      │
              │  own OIDC issuer / IRSA│   │  Karpenter workload pool│
              └────────────────────────┘   └────────────────────────┘
                          │      Cilium Cluster Mesh (ENI IPAM,        │
                          └──────────── WireGuard) over the same TGW ──┘
```

Both `live/hub` and `live/spoke` are structurally near-identical roots -
`vpc → tgw-attachment → eks → eks-node-role → eks-node-group → irsa →
(s3 | karpenter role)` - differing mainly in a handful of flags
(`enable_karpenter_discovery`, whether S3 buckets or a Karpenter IRSA role
exist, `install_cni_ccm`).

**Ingress note:** `modules/alb` and `modules/acm` are present but **not
instantiated** by either root today. Application ingress happens inside
the cluster (NGINX Ingress / Gateway API via Argo CD → a CCM-provisioned
NLB) - there is no Terraform-managed internet-facing load balancer yet.

---

## Key design decisions (the "why" behind the shape of this repo)

- **Each cluster has its own OIDC issuer.** IRSA (`modules/irsa`) is
  instantiated once per cluster rather than shared, so a pod identity
  token minted on one cluster can never validate against another
  cluster's provider.
- **Node role and node group are separate modules.** EKS's API auth mode
  requires an access entry to exist *before* an instance using that role
  tries to join. Splitting `eks-node-role` out from `eks-node-group` lets
  callers force that ordering with an explicit `depends_on`, instead of
  relying on an implicit dependency edge that isn't actually there.
- **Karpenter runs on the stable Managed Node Group, not the pool it
  manages.** Terminating the controller's own node mid-drain would be a
  self-inflicted outage - same reasoning the pre-migration design used
  when Karpenter ran on the kubeadm master.
- **The hub gets Cilium + AWS CCM installed imperatively via CI, once.**
  Argo CD's own pods need real pod networking to schedule, but pod
  networking is normally installed *by* Argo CD (Cilium as an
  Application) - chicken-and-egg. So on the hub only, CI installs Cilium
  (hostNetwork DaemonSet, schedules even on `NotReady`/no-CNI nodes) +
  CCM first, waits for `Ready`, and only then lets Argo CD "adopt" them.
  Spokes skip this: the hub's Argo CD reaches a spoke's API server
  directly over TGW and installs Cilium there after registration.
- **GitOps registration is push-then-pull, not `argocd cluster add`.** A
  spoke pushes `{name, role, server, token, caData}` to Secrets Manager;
  External Secrets Operator on the hub (its own IRSA role) turns that into
  a labeled `Secret`; Argo CD picks it up because it matches the label
  selector. CI's job stops at the push - it never talks to Argo CD
  directly.
- **Teardown deliberately deregisters from Argo CD before draining PVCs.**
  If a spoke's `selfHeal: true` Applications are still live while PVCs are
  being deleted, Argo CD can race the drain and try to recreate what's
  being torn down. `k8s-deregister-from-hub.yml` removes the spoke from
  Argo CD's live inventory (fails loudly if it can't confirm that) before
  `drain-cluster.yml` touches anything.
- **S3 backend uses native locking, no DynamoDB table.** `use_lockfile =
  true` on the `s3` backend block is enough for state locking across all
  three roots.

---

## Repo layout

```
global/network/          Shared Transit Gateway (its own state/root)
live/hub/                Hub cluster root module (EKS + Argo CD)
live/spoke/              Spoke cluster root module (EKS + app workloads)
modules/                 Reusable Terraform modules
.github/workflows/       CI (lint/validate) + CD (deploy/destroy) pipelines
.github/scripts/         Shell templates run against clusters (drain, deregister, bootstrap)
.github/actions/         Shared composite actions (eks-connect)
.tflint.hcl              Lint ruleset (local module sources intentionally unpinned)
```

### Terraform modules

| Module | Purpose | Wired into `live/*`? |
|---|---|---|
| [`vpc`](modules/vpc/README.md) | VPC, public/private subnets, NAT Gateway, S3 gateway endpoint, SSM interface endpoints, optional `karpenter.sh/discovery` tagging | Yes |
| `eks` | EKS control plane, cluster IAM role, additional control-plane SG, OIDC issuer output | Yes |
| `eks-node-role` | Node-pool IAM role (worker policy, ECR read-only, SSM) - split from `eks-node-group` so its access entry can exist before nodes join | Yes |
| `eks-node-group` | Managed Node Group for the baseline "platform" pool (Argo CD, cilium-operator, coredns, cert-manager, external-secrets, etc.) | Yes |
| [`irsa`](modules/irsa/README.md) | Registers a cluster's OIDC issuer with AWS + one trust-scoped IAM role per ServiceAccount | Yes |
| `tgw-attachment` | Attaches a cluster's VPC to the shared TGW, adds routes toward peer CIDR(s) | Yes |
| [`s3`](modules/s3/README.md) | Application/cluster S3 buckets (Loki/Tempo) | Hub only |
| [`ami`](modules/ami/README.md) | Looks up the newest Packer-built `k8s-base` AMI | **Legacy** - pre-EKS, unreferenced by `live/*` |
| `alb` | Internet-facing ALB, per-app target groups, host-based HTTPS routing | **Not instantiated** |
| [`acm`](modules/acm/README.md) | ACM certificate for an ALB's HTTPS listener | **Not instantiated** |

---

## Pipelines

Every root's `terraform init → plan[-destroy] → apply` boilerplate lives in
one reusable workflow, `terraform-apply.yml`, parameterized by working
directory, `destroy`/`use_var_file` flags, and extra `-var` args. Everything
below calls into it rather than duplicating those steps.

### Deploy

| Workflow | Scope |
|---|---|
| `deploy-network.yml` | `global/network` only - rare (e.g. `amazon_side_asn` changes) |
| `deploy-hub.yml` | `live/hub` apply → `k8s-cluster-bootstrap.yml` (Cilium/CCM) → `k8s-bootstrap-argocd.yml` |
| `deploy-spoke-infra.yml` | `live/spoke` (or any `spoke_dir`) apply → apiserver reachability check → `k8s-register-with-hub.yml`. Stops short of verifying the hub actually picked up the registration |
| `deploy-spoke.yml` | `deploy-spoke-infra.yml` + `verify-spoke-registration.yml` - full single-spoke chain, for day-2 changes |
| `deploy-all.yml` | **First-time bring-up only**: `deploy-network` → `{deploy-hub, deploy-spoke-infra}` in parallel → `verify-spoke-registration`. Hub and spoke can run in parallel because spoke's state has no dependency on hub's; only the final registration check needs both finished |

For any day-2 change to a single cluster, use the narrower workflow -
`deploy-all.yml` forces every cluster's bootstrap/Argo CD steps to
re-run even for an unrelated change.

### Destroy

| Workflow | Scope |
|---|---|
| `k8s-deregister-from-hub.yml` | Spoke only - removes it from Argo CD's live inventory first. Not tolerant of failure: a partial deregistration means the drain step that follows isn't actually race-free, so the pipeline stops |
| `drain-cluster.yml` | (optional) freeze local Argo CD → LoadBalancer Service drain → PVC drain (namespace-cascade) → Karpenter node drain (spoke only, must run last - earlier steps still need live worker nodes) |
| `terraform-destroy-hub.yml` / `terraform-destroy-spoke.yml` | `terraform destroy` for that root only |
| `destroy-hub.yml` | `drain-cluster` → `terraform-destroy-hub` |
| `destroy-spoke.yml` | `k8s-deregister-from-hub` → `drain-cluster` → `terraform-destroy-spoke` |
| `destroy-all.yml` | Full environment teardown, sequenced so `deregister-from-argocd` runs first (needs the hub alive), spoke/hub then drain and destroy **in parallel**, `global/network` destroyed **last** |
| `destroy-network.yml` | `global/network` - must run after both `destroy-hub` and `destroy-spoke` (both roots read its TGW id via `terraform_remote_state`) |

### CI (`terraform.yml`)

Runs on every PR touching `.tf`/`.tfvars`/`.pkr.hcl`, and on every push:
`terraform fmt -check`, `terraform validate` (matrix over `global/network`,
`live/hub`, `live/spoke`, `init -backend=false` - no real credentials
needed), `tflint` (same matrix), and a repo-wide `trivy` config scan.

---

## IAM model

Two distinct mechanisms, worth keeping separate in your head:

1. **EKS access entries** (`aws_eks_access_entry` /
   `aws_eks_access_policy_association`) - authorize a *principal* (a node
   role, or a human/CI role) to talk to the Kubernetes API at all. This
   replaces the old `aws-auth` ConfigMap model. Every node role and the CI
   role (`argocd_registration_ci`) needs one.
2. **IRSA** (`modules/irsa`) - authorizes a specific pod's *ServiceAccount*
   (via `sts:AssumeRoleWithWebIdentity` against that cluster's own OIDC
   issuer) to call AWS APIs, independent of which node it lands on. Used
   by Cilium's ENI operator, AWS CCM, the EBS CSI driver, External Secrets
   Operator, Karpenter, and (hub only) Loki/Tempo.

CI reaches clusters directly (`aws eks update-kubeconfig` + kubectl/helm) -
there's no master instance and no SSM tunnel anymore. `argocd_registration_ci`
is a GitHub OIDC-federated role, holding an access entry with
`AmazonEKSAdminPolicy` on the target cluster.

---

## Cluster Mesh

Cilium runs in **ENI IPAM mode** - pods get real VPC IPs from the
cluster's own subnets. Cross-cluster reachability relies on:

- Every cluster's VPC attached to the shared TGW with routes toward every
  peer's CIDR (`modules/tgw-attachment`).
- `routingMode=native`, `kubeProxyReplacement=true`, NodePort range
  `30000-32767`.
- WireGuard (UDP 51871) between real node IPs.
- `clustermesh-apiserver` on a fixed NodePort, reachable from the fleet's
  VPC-CIDR supernet.
- The Cluster Mesh CA pushed by the hub / pulled by each spoke via ESO,
  authenticated through the `external-secrets` IRSA role on each cluster.

Both `live/hub/main.tf` and `live/spoke/main.tf` run a `check` block that
asserts all relevant VPC CIDRs are disjoint, so a bad CIDR fails at
`terraform plan` instead of deep inside a TGW route apply.

---

## Karpenter

Spoke-only (`enable_karpenter_discovery = false` on the hub). Runs on the
platform Managed Node Group, not the elastic pool it provisions. It owns
its own instance profile (built from `EC2NodeClass.spec.role`, i.e. the
node role's *name*, not an ARN) - unlike the pre-migration design, there's
no `iam:PassRole` onto a Terraform-managed instance profile. Because
Karpenter-provisioned instances aren't Terraform-managed at all, teardown
has a dedicated step (`drain-karpenter-nodes.sh.tpl`, gated by
`has_karpenter` on `drain-cluster.yml`) that deletes NodeClaims via the
Kubernetes API, with a direct `ec2:TerminateInstances` fallback if the
controller is unresponsive.

---

## State & backend

S3 backend with native locking (`use_lockfile = true`, no DynamoDB table),
bucket `terraform-phuoctd6`, region `ap-northeast-1`. Each root's `key` is
supplied at `terraform init` time via `-backend-config=envs/<env>/backend.hcl`,
so `backend.tf` stays identical across environments.

| Root | State key |
|---|---|
| `global/network` | `global/network/<env>/terraform.tfstate` |
| `live/hub` | `hub/<env>/terraform.tfstate` |
| `live/spoke` | `spoke/<env>/terraform.tfstate` |

`live/hub` and `live/spoke` each read `global/network`'s state via
`terraform_remote_state` - one-directional, network never reads back.

---

## Apply / teardown order

```
Apply:    1. global/network  2. live/hub  3. live/spoke
Teardown: 1. deregister spoke from hub Argo CD
          2. drain spoke + drain hub        (parallel)
          3. terraform destroy spoke + hub  (parallel)
          4. global/network                 (last)
```

### Adding a second spoke

1. Copy `live/spoke` → `live/spoke-2` (new backend key, a `vpc_cidr`
   disjoint from every existing cluster, new `envs/<env>/terraform.tfvars`).
2. Add its CIDR to `live/hub`'s `spoke_vpc_cidrs` and re-apply the hub
   (needed for the TGW route + `trusted_api_cidr_blocks`).
3. Run `deploy-spoke.yml` with `spoke_dir: live/spoke-2`.

---

## Known drift / things worth cleaning up

A few artifacts survived the kubeadm→EKS migration without being fully
retired. None of these are actively harmful, but they're worth knowing
about before you go looking for what calls them:

- **`.github/scripts/register-with-hub.sh.tpl` is dead code.** It
  installs a systemd timer on a host to rotate the `argocd-manager` token
  every 30 days. `k8s-register-with-hub.yml` replaced this entirely - SA
  creation and the Secrets Manager push are now inline steps in that
  workflow, and rotation runs as a scheduled GitHub Actions job instead
  (see that workflow's header comment). No workflow references this
  script anymore; it's safe to delete or explicitly mark archived.
- **`modules/ami` is legacy.** Looks up the old Packer-baked
  `containerd`/`kubeadm`/`kubelet` base image. Nothing under `live/*`
  references it post-migration - node AMIs now come from `ami_type` on
  the Managed Node Group.
- **`modules/alb` and `modules/acm` are unwired.** Both are fully built
  and documented but no root instantiates them. If ALB-fronted ingress is
  actually planned, wire it into `live/hub` or a shared root; otherwise
  consider whether they should move to an `examples/` or `legacy/`
  directory so "present in the repo" doesn't imply "in use."

---

## What changed in the EKS migration

| Area | Before (kubeadm on EC2) | Now (EKS) |
|---|---|---|
| Control plane | Self-managed on a master EC2 instance, `kubeadm init` via SSM | AWS-managed (`aws_eks_cluster`) - no master instance |
| Worker nodes | `modules/asg` + Launch Template, `kubeadm join` at boot | `modules/eks-node-group` Managed Node Group |
| Node IAM auth | Broad node instance-profile roles | EKS access entries (`modules/eks-node-role`) |
| AMI | Custom Packer `k8s-base` AMI (`modules/ami`) | EKS-optimized AMI via `ami_type` |
| OIDC / IRSA issuer | Self-hosted, hand-published to a public-read S3 bucket (`modules/oidc-bucket`) | EKS's built-in OIDC endpoint |
| Cluster access | `aws ssm start-session` to the master | Direct `aws eks update-kubeconfig` + kubectl/helm |
| CI → cluster auth | SSM `send-command`, IAM scoped to SSM actions | Access entry + `AmazonEKSAdminPolicy` on a GitHub OIDC role |
| Karpenter placement | On the master | On the platform Managed Node Group |
| Teardown | Drain scripts run over SSM against the master | Same scripts, run directly via `aws eks update-kubeconfig` |
| Modules removed | `modules/ec2`, `modules/asg`, `modules/k8s`, `modules/oidc-bucket` | - |
| Modules added | - | `modules/eks`, `modules/eks-node-role`, `modules/eks-node-group` |

---

## Where to look next

- Each module's own `README.md` has its full resource table and variable
  reference - read it before changing that module's `main.tf`.
- Every workflow file's header comment explains *why* it's split the way
  it is (parallelism, race-freedom on teardown, the specific EKS-vs-kubeadm
  rewrite it went through) - treat those as the source of truth over this
  summary for edge cases.
- `modules/irsa/README.md` for the full IRSA mechanic and how to onboard a
  new workload.
- Registration flow in detail: `k8s-register-with-hub.yml` (spoke pushes
  a token) → External Secrets Operator on the hub (reads it, IRSA-scoped
  to `argocd-clusters/*`) → `argocd/clusters/<name>.yaml` in the separate
  `gitops` repo (the actual GitOps fact) → `root-clusters` Application
  reconciles the `ExternalSecret` from there.