# kubeadm on AWS - Hub/Spoke Kubernetes Infrastructure

A Terraform + Packer + GitHub Actions monorepo that stands up one or more
**self-managed kubeadm clusters on AWS**, wired together in a **hub/spoke**
topology over a shared Transit Gateway, with **Cilium Cluster Mesh** giving
every cluster's pods a flat, routable address space. The **hub** cluster
runs Argo CD as the fleet's GitOps control plane; **spoke** clusters run
application workloads and register themselves into the hub's Argo CD
automatically.

If you're new to the repo, read this file top to bottom once, then use the
per-module `README.md` files (`modules/*/README.md`) as reference docs while
you work.

> **Doc freshness note:** this file was refreshed to match the code as of
> the ENI-mode Cilium + IRSA + Karpenter changes. `modules/ec2/README.md`
> still describes the pre-IRSA node-role model (`install_eso`,
> `install_clustermesh_ca_push/pull`, etc.) and needs a follow-up rewrite -
> see the callout in "IAM model" below for what actually replaced it.

---

## Architecture at a glance

```
                        ┌───────────────────────────┐
                        │   global/network (TGW)     │
                        │  shared Transit Gateway     │
                        │  + shared IRSA OIDC bucket   │
                        │  state: its own root/backend│
                        └──────────────┬─────────────┘
                                       │ transit_gateway_id, oidc_bucket_*
                          ┌────────────┴─────────────┐
                          │  (read via terraform_     │
                          │   remote_state, one-way)  │
              ┌───────────▼───────────┐   ┌───────────▼───────────┐
              │       live/hub          │   │      live/spoke        │
              │  VPC 10.0.0.0/16       │◄──┤  VPC 10.1.0.0/16       │
              │  runs: Argo CD (GitOps)│TGW│  runs: app workloads   │
              │  own OIDC issuer/IRSA  │   │  own OIDC issuer/IRSA  │
              │  ASG workers            │   │  ASG workers + Karpenter│
              └────────────────────────┘   └────────────────────────┘
                          │  Cilium Cluster Mesh (ENI IPAM, WireGuard)│
                          └──────────────────── over the same TGW ──────────┘
```

* **`global/network`** - a shared Transit Gateway (TGW) **and** the shared,
  public-read S3 bucket (`modules/oidc-bucket`) that hosts every cluster's
  IRSA OIDC discovery document + JWKS. Applied once, independently, before
  hub or spoke.
* **`live/hub`** - one Kubernetes cluster whose main job is to run
  **Argo CD**, the GitOps controller for the whole fleet.
* **`live/spoke`** - one Kubernetes cluster that runs actual application
  workloads. Additional spokes are added by copying this root (e.g.
  `live/spoke-2`) - see "Adding a second spoke" below.
* Hub and spoke VPCs are connected through the shared TGW so the hub's
  Argo CD can reach each spoke's `kube-apiserver` directly (pull-based
  GitOps against every registered cluster), and so cross-cluster pod
  traffic (Cluster Mesh) can be natively routed.
* Each cluster registers its **own IRSA OIDC issuer** (`modules/irsa`),
  independent kubeadm SA signing keys, so a pod identity from one cluster
  can never validate against another cluster's provider.

Both `live/hub` and `live/spoke` are structurally near-identical roots
(vpc → tgw-attachment → ami → irsa → k8s scripts → ec2 master → asg workers
→ s3/none), differing mainly in a handful of flags (`register_with_hub`,
`install_cni_ccm`, `enable_karpenter_discovery`, whether S3 buckets or a
Karpenter IRSA role exist).

**Ingress note:** `modules/alb` and `modules/acm` exist in this repo but
**neither `live/hub` nor `live/spoke` currently instantiates them** - no
`module "alb"` / `module "acm"` block exists in either root's `main.tf`.
Treat those two modules as reserved/legacy for now. Application ingress
today happens inside the cluster (NGINX Ingress / Gateway API via Argo CD,
forwarding to the worker `NodePort` range or a CCM-provisioned NLB), there
is no Terraform-managed internet-facing load balancer at the moment.

---

## Repo layout

```
global/network/          Shared Transit Gateway + shared IRSA OIDC bucket
live/hub/                Hub cluster root module (Argo CD)
live/spoke/              Spoke cluster root module (app workloads)
modules/                 Reusable Terraform modules (see table below)
packer/                  Packer + Ansible build for the shared k8s base AMI
.github/workflows/       CI (lint/validate) + CD (deploy/destroy) pipelines
.github/scripts/         Shell script templates run on cluster nodes via SSM
.github/actions/         Shared composite actions (SSM send-command + poll)
```

### Terraform modules

| Module | Purpose | Wired into `live/*` today? |
|---|---|---|
| [`vpc`](modules/vpc/README.md) | VPC, public/private subnets, a NAT **Gateway** (AWS-managed, not an EC2 instance), S3 gateway endpoint, SSM interface endpoints, optional `karpenter.sh/discovery` subnet tagging | Yes |
| [`ami`](modules/ami/README.md) | Looks up the newest Packer-built k8s base AMI (`purpose=k8s-base` tag) | Yes |
| [`ec2`](modules/ec2/README.md) | Master node + shared security groups for master/workers, Cluster Mesh SG rules, join-token SSM parameter. **IAM has shrunk** - see "IAM model" below; most controller permissions now come from `modules/irsa` instead of the node role. **Doc is stale, pending rewrite.** | Yes |
| [`asg`](modules/asg/README.md) | Worker Launch Template + Auto Scaling Group, tagged for Cluster Autoscaler discovery | Yes |
| [`irsa`](modules/irsa/README.md) | Registers this cluster's OIDC issuer with AWS and creates one trust-scoped IAM role per ServiceAccount (EBS CSI, ESO, CCM, cilium-operator, Karpenter, Loki/Tempo on the hub) | Yes |
| [`oidc-bucket`](modules/oidc-bucket/README.md) | The one shared, public-read S3 bucket every cluster publishes its OIDC discovery doc + JWKS to | Yes (via `global/network`) |
| [`tgw-attachment`](modules/tgw-attachment) | Attaches a cluster's VPC to the shared TGW and adds peer routes | Yes |
| [`k8s`](modules/k8s/README.md) | Renders `master_userdata` / `worker_userdata` bootstrap scripts (content only - doesn't attach or run anything) | Yes |
| [`s3`](modules/s3/README.md) | Application/cluster S3 buckets (Loki/Tempo on the hub) | Hub only |
| [`alb`](modules/alb) | Internet-facing ALB, per-app target groups, host-based HTTPS routing to the NodePort | **Not instantiated** - present but unused |
| [`acm`](modules/acm/README.md) | ACM certificate for an ALB's HTTPS listener | **Not instantiated** - present but unused |

---

## What's baked into the AMI vs. what runs at bootstrap time

Node bring-up is split across three layers:

| Layer | What it does | When it runs | Where it lives |
|---|---|---|---|
| **Packer + Ansible** (`/packer`) | swap off, kernel modules, sysctl, containerd, kubeadm/kubelet/kubectl install, Helm install, disable-source-dest-check unit | Once, ahead of time, produces an AMI | `packer/ansible/playbook.yml` |
| **`user_data` / CI script** | `kubeadm init` or `kubeadm join`, publish IRSA OIDC discovery docs, Cilium CNI (Helm, ENI IPAM + WireGuard), AWS CCM | At node launch / cluster bootstrap | `modules/k8s/templates/*.tpl` |
| **Argo CD (GitOps)** | Everything else: CCM/Cilium upgrades on spokes, External Secrets Operator, application workloads, Cluster Mesh CA distribution | Continuously, reconciling from Git | separate `gitops` repo (referenced by raw URL) |

* **AMI baking** removes repeated package installs from every boot.
* `kubeadm init` runs via `k8s-cluster-bootstrap.yml` (SSM `send-command`),
  not master `user_data` - a failed bootstrap shows up as a failed GitHub
  Actions job with logs.
* Workers still run `kubeadm join` from `user_data` at launch time (Cluster
  Autoscaler scale-out has no CI trigger to hook into), polling SSM for the
  join token (`modules/k8s/templates/worker_init.sh.tpl`).
* Immediately after `kubeadm init`, the master publishes kube-apiserver's
  own OIDC discovery doc + JWKS (fetched live off `localhost:6443`, never
  hand-derived) to the shared `oidc-bucket`, so IRSA `AssumeRoleWithWebIdentity`
  calls can be validated before Cilium/CCM even start.
* CNI (Cilium) is installed via `helm upgrade --install` directly inside
  `master_init.sh.tpl` when `install_cni_ccm = true` (hub). It now runs
  **`ipam.mode=eni`** (`eni.enabled=true`, `awsEnablePrefixDelegation=true`)
  - pods get real VPC IPs instead of a separate pod-CIDR block - with
  `routingMode=native`, `kubeProxyReplacement=true`, and
  `encryption.type=wireguard`. The operator authenticates to AWS via an
  IRSA role (`cilium-operator`, projected service-account token), not the
  node's instance profile. Spokes set `install_cni_ccm = false`; Argo CD's
  own `ApplicationSet` installs Cilium + AWS CCM on a spoke once it
  registers.
* AWS CCM is installed the same way, unconditionally, on every cluster -
  every node carries the
  `node.cloudprovider.kubernetes.io/uninitialized:NoSchedule` taint from
  `cloud-provider=external` until CCM clears it, and that has to happen
  before anything (including Argo CD's own pods) can schedule. CCM also
  authenticates via its own IRSA role now, not the node role.

---

## IAM model: IRSA, not node roles

Most AWS-facing controllers (Cilium's ENI operator, AWS CCM, the EBS CSI
driver, External Secrets Operator, Karpenter, and - on the hub - Loki/Tempo)
now authenticate as a **specific pod's ServiceAccount** via IRSA
(`modules/irsa`), not as "whichever node the pod happens to land on" via a
broad node instance-profile role. Each cluster:

1. Registers its own `aws_iam_openid_connect_provider` pointed at its
   kubeadm-generated issuer (`modules/irsa`).
2. Creates one narrowly-scoped `aws_iam_role` per workload, trusted only
   for `system:serviceaccount:<namespace>:<name>` via that provider
   (`live/hub/main.tf` / `live/spoke/main.tf`'s `roles = { ... }` maps).
3. Injects the role ARN + a projected service-account token directly into
   the day-0 Helm installs in `master_init.sh.tpl` (Cilium operator, AWS
   CCM) since neither the pod-identity webhook nor Argo CD exists yet at
   that point in bootstrap; Argo CD-managed workloads (ESO, EBS CSI,
   Karpenter, Loki, Tempo) pick up the same role ARNs via ServiceAccount
   annotations in the `gitops` repo.

**What this replaced (and where `modules/ec2/main.tf`'s IAM footprint
shrank to):** the master/worker roles now carry only SSM access, the
join-token SSM write, the OIDC-publish `s3:PutObject` grant scoped to the
cluster's own prefix, and (spokes only) the scoped
`argocd-clusters/<cluster_name>-*` registration-push grant. The former
`install_eso`, `install_clustermesh_ca_push` / `install_clustermesh_ca_pull`
flags and their IAM policies, the ESO bootstrap IAM user, and the
CCM/Cluster-Autoscaler node-role policies described in
`modules/ec2/README.md` **no longer exist in code** - that doc needs a
rewrite to match. Cluster Mesh CA push/pull is now handled by the
`external-secrets` IRSA role's policy (`eso_irsa_policy_hub` /
`eso_irsa_policy_spoke` in `live/*/main.tf`), scoped to `clustermesh/*`,
exactly like it used to be scoped on the node role.

See `modules/irsa/README.md` for the full mechanic and how to onboard a
new workload.

---

## Cluster Mesh (cross-cluster pod networking)

Cilium runs in **ENI IPAM mode** (`ipam.mode=eni`), not the older
pod-CIDR-per-cluster model - pods are allocated real VPC IPs out of the
cluster's own subnets (via ENI secondary IPs / prefix delegation), so
there is no separate pod-CIDR supernet to route through the TGW anymore.
Cross-cluster pod reachability instead relies on:

* Every cluster's VPC being attached to the shared TGW
  (`modules/tgw-attachment`) with routes toward every peer cluster's VPC
  CIDR (`peer_cidr_blocks`) - since pod IPs now live inside that same VPC
  CIDR, the existing VPC-to-VPC TGW routes carry pod traffic too.
* `routingMode=native` / `autoDirectNodeRoutes=false` on Cilium, with
  `kubeProxyReplacement=true` and NodePort range `30000-32767`.
* All inter-node traffic (intra- and cross-cluster) re-encapsulated as
  WireGuard (`cilium_wg0`, UDP/51871) between real node IPs -
  `encryption.enabled=true`, `encryption.type=wireguard`.
* The `clustermesh-apiserver` Service exposed on a fixed `NodePort`
  (`clustermesh_nodeport`, default `32379`), reachable from any cluster in
  the fleet's VPC-CIDR supernet (`vpc_cidr_supernet`, default `10.0.0.0/8`) -
  both the master and worker security groups admit this port from that
  supernet.
* The CA Cluster Mesh uses is pushed by the hub and pulled by each spoke
  via External Secrets Operator, now authenticated through the
  `external-secrets` IRSA role on each cluster (scoped to `clustermesh/*`
  in Secrets Manager) rather than a node-role IAM grant.

`live/hub/main.tf` and `live/spoke/main.tf` each run a `check` block that
converts every relevant VPC CIDR to numeric ranges and asserts they're
disjoint - this catches a bad CIDR at `terraform plan` time instead of
deep inside a failed TGW route apply. (There is no `pod_cidr` variable or
check anywhere in the current code - it was removed along with the
pod-CIDR IPAM mode.)

---

## Karpenter (spoke node autoscaling)

Spokes now run **Karpenter on the master** (moved off worker nodes to
avoid a self-termination race where deleting the node hosting the
controller would kill the controller mid-drain of other nodes), alongside
the existing ASG-managed worker pool (`modules/asg` still provisions the
baseline worker Launch Template/ASG on every cluster). Karpenter has its
own IRSA role (`karpenter_irsa_policy` in `live/spoke/main.tf`) scoped to
fleet discovery/provisioning/termination of instances tagged for this
cluster, and is granted `iam:PassRole` on the existing worker role/profile
(`module.ec2.worker_iam_role_arn` / `worker_iam_instance_profile_arn`) so
Karpenter-launched nodes get the same permissions as ASG-launched ones.
The hub does **not** run Karpenter (`enable_karpenter_discovery = false`
on the hub's `vpc` module call).

Because Karpenter-provisioned instances are not Terraform-managed
(Karpenter calls `ec2:RunInstances` directly), teardown has a dedicated
step - see `.github/scripts/drain-karpenter-nodes.sh.tpl` and the
`has_karpenter` input on `drain-cluster.yml` - to deprovision them via the
Kubernetes API (NodePool/NodeClaim deletion) before `terraform destroy`
runs, with a direct EC2-termination fallback if the controller is
unresponsive. This runs **last** in the drain sequence, after the
load-balancer and PVC drains, since those still need live worker nodes.

---

## Access model

Master nodes have **no public IP**. The primary access path is
**AWS SSM Session Manager**:

```bash
aws ssm start-session --target <master_instance_id>
```

`master_instance_id` is a Terraform output on both `live/hub` and
`live/spoke`. This works because the master's IAM role has
`AmazonSSMManagedInstanceCore` attached unconditionally, and `modules/vpc`
provisions the three SSM interface VPC endpoints (`ssm`, `ssmmessages`,
`ec2messages`) required for the agent to reach Session Manager without a
route to the public internet.

SSH (port 22) still works as a fallback, but only from inside the VPC - it
is not reachable from the internet.

---

## How a spoke joins the hub's Argo CD (GitOps registration)

1. **Terraform (`live/spoke`)** provisions the spoke cluster; the master's
   IAM role is granted permission to write only to
   `argocd-clusters/<cluster_name>-*` in Secrets Manager
   (`register_with_hub = true`).
2. **CI (`k8s-register-with-hub.yml`)** runs `register-with-hub.sh.tpl` on
   the spoke master over SSM: creates an `argocd-manager` service account
   with `cluster-admin`, mints a token, and pushes
   `{name, role, server, token, caData}` to Secrets Manager, plus a systemd
   timer that re-pushes a fresh token every 30 days.
3. **On the hub**, External Secrets Operator (now authenticated via its own
   IRSA role, see "IAM model" above) reads that path and materializes a
   Kubernetes `Secret` labeled
   `argocd.argoproj.io/secret-type=cluster,cluster-name=<name>`.
4. Argo CD sees the labeled Secret and treats the spoke as registered - no
   `argocd cluster add` step.
5. **CI (`verify-spoke-registration.yml`)** polls the hub for that Secret
   (filtered by the `cluster-name` label) to confirm the pipeline actually
   completed, failing loudly with a checklist of likely causes on timeout.

Registering a cluster with Argo CD itself is a **GitOps fact**: add
`argocd/clusters/<name>.yaml` to the separate `gitops` repo once; the
`root-clusters` Application (selfHeal) reconciles the `ExternalSecret` for
every registered cluster from there.

---

## Networking notes

* **NAT Gateway**, not a NAT instance. `modules/vpc` provisions an
  AWS-managed `aws_nat_gateway` with its own Elastic IP in the first public
  subnet - all private subnets route `0.0.0.0/0` through it.
* **S3 traffic bypasses the NAT Gateway** via a Gateway VPC endpoint.
* **CIDR overlap guard.** Both `live/hub/main.tf` and `live/spoke/main.tf`
  assert VPC CIDRs are disjoint (no `pod_cidr` check anymore - see Cluster
  Mesh section above).
* **No Terraform-managed internet-facing load balancer today** - see the
  "Ingress note" in the Architecture section above.

---

## Apply order (first-time bring-up)

```
1. global/network   (shared TGW + shared IRSA OIDC bucket - must exist before hub or spoke)
2. live/hub         (terraform apply → kubeadm bootstrap → Argo CD install)
3. live/spoke       (terraform apply → kubeadm bootstrap → register with hub → verify)
```

Use **`deploy-all.yml`** to run a first-time bring-up: it chains
`deploy-network` → `{deploy-hub, deploy-spoke-infra}` in parallel →
`verify-spoke-registration`. Hub and spoke can run in parallel because
spoke's Terraform state has no dependency on hub's (`hub_vpc_cidr` is a
plain tfvar, not a `terraform_remote_state` read); only the final
registration check needs both to have finished, since it needs the hub's
Argo CD + ESO actually running.

| Workflow | Scope |
|---|---|
| `deploy-network.yml` | `global/network` only - rare, e.g. changing `amazon_side_asn` |
| `deploy-hub.yml` | `live/hub` terraform apply → `k8s-cluster-bootstrap.yml` (kubeadm/Cilium/CCM) → `k8s-bootstrap-argocd.yml` (Argo CD install + seed ESO creds) |
| `deploy-spoke-infra.yml` | `live/spoke` (or any `spoke_dir`) terraform apply → `k8s-cluster-bootstrap.yml` → `k8s-register-with-hub.yml`. Deliberately stops short of verifying the hub picked up the registration. |
| `deploy-spoke.yml` | `deploy-spoke-infra.yml` + `verify-spoke-registration.yml` - the full single-spoke chain for a day-2 change |
| `deploy-all.yml` | First-time bring-up only: `deploy-network` → `{deploy-hub, deploy-spoke-infra}` (parallel) → `verify-spoke-registration` |
| `packer-build-ami.yml` | Manual only - builds a new base AMI (never runs on push/PR) |

For any day-2 change to a single cluster, use the narrower workflow instead
of `deploy-all.yml` - it won't force an unrelated cluster's bootstrap/Argo
CD steps to re-run.

### Adding a second spoke later

1. Copy `live/spoke` → `live/spoke-2` (new backend key, new `vpc_cidr`
   disjoint from every other cluster, new `envs/<env>/terraform.tfvars`).
2. Add its CIDR to `live/hub`'s `spoke_vpc_cidrs` and re-apply the hub
   (needed for the TGW route + apiserver trust, `trusted_api_cidr_blocks`).
3. Run `deploy-spoke.yml` (or `deploy-all.yml`'s pattern) with
   `spoke_dir: live/spoke-2`.

---

## Teardown order

```
1. deregister-from-argocd  (spoke only - must run while the hub master is
                             still alive, before either cluster is drained)
2. drain-spoke + drain-hub                    (parallel)
3. terraform-destroy-spoke + terraform-destroy-hub   (parallel)
4. global/network                              (last - hub/spoke state
                                                 both read its TGW id)
```

`drain-cluster.yml` (used for both hub and spoke) runs, in order: optional
local Argo CD freeze (hub only) → LoadBalancer Service drain (CCM releases
its NLB/ALB/Classic ELB) → PVC drain (namespace-cascade, releases CSI
volumes) → **Karpenter node drain** (spoke only, `has_karpenter: true`;
deprovisions NodeClaims via the K8s API with a direct EC2-termination
fallback) - Karpenter must run last since the earlier steps still need
live worker nodes.

| Workflow | Scope |
|---|---|
| `k8s-deregister-from-hub.yml` | Spoke only - temporarily removes the spoke from ArgoCD's live inventory (deletes `root-clusters` with `cascade=orphan`, then the spoke's `ExternalSecret`/`Secret`, then every generated Application in reverse sync-wave order except node-critical infra) so nothing can resurrect a workload while draining runs. Not tolerant of failure. |
| `drain-cluster.yml` | Load-balancer drain → PVC drain → Karpenter node drain (spoke only), before that cluster's infra is torn down. Best-effort - logs a warning rather than failing. Optionally freezes the local Argo CD controllers first (`freeze_argocd_namespace`, used on the hub). |
| `terraform-destroy-hub.yml` / `terraform-destroy-spoke.yml` | `terraform destroy` for that root only |
| `destroy-hub.yml` | `drain-cluster` → `terraform-destroy-hub`, hub only |
| `destroy-spoke.yml` | `k8s-deregister-from-hub` → `drain-cluster` → `terraform-destroy-spoke`, one spoke only |
| `destroy-all.yml` | Full environment teardown: `deregister-from-argocd` → `{drain-spoke, drain-hub}` (parallel) → `{terraform-destroy-spoke, terraform-destroy-hub}` (parallel) → `destroy-network` |
| `destroy-network.yml` | `global/network` - **run last**; both hub and spoke state reference its TGW id via `terraform_remote_state` |

Destroying a single cluster (hub or spoke) doesn't require touching
`global/network` or the other cluster - use `destroy-hub.yml` /
`destroy-spoke.yml` directly. PVCs backed by a StatefulSet's
`volumeClaimTemplate` (Prometheus, Tempo ingester) are not deleted by the
ArgoCD deregistration step; `drain-cluster.yml`'s namespace-delete approach
is what actually releases those. Karpenter-managed nodes are not
Terraform-managed at all - undrained, they can make `terraform destroy`
fail outright on VPC/security-group deletion, not just leak cost.

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
`terraform_remote_state` (one-directional) - this is also how they get
`oidc_bucket_id` / `oidc_bucket_arn` / `oidc_bucket_regional_domain_name`
for IRSA.

---

## CI checks (`terraform.yml`, on every PR touching `.tf`/`.tfvars`/Packer files, and on every push)

* `terraform fmt -check`
* `terraform validate` (matrix: `global/network`, `live/hub`, `live/spoke`; `init -backend=false`, no real credentials needed)
* `tflint` (matrix, same three roots - see `.tflint.hcl` for enabled rules)
* `packer validate` + `packer fmt -check` + `ansible-lint` (static only - CI has no AWS credentials, so it cannot actually launch a build instance)
* `trivy` config scan across the whole repo

---

## Security notes worth knowing

* Master/worker security groups use
  `lifecycle { ignore_changes = [ingress, egress] }` so Terraform doesn't
  fight AWS Cloud Controller Manager, which adds its own SG rules for
  LoadBalancer-type Services at runtime.
* Most controller AWS permissions are IRSA roles scoped to one
  ServiceAccount each (see "IAM model" above), not the broad node roles -
  the node roles now carry only SSM access, the join-token SSM write, the
  OIDC-publish grant, and (spokes) the scoped Argo CD registration-push
  grant.
* The join-token SSM parameter (`/<env>/k8s/join_token`) is a
  `SecureString`; Terraform ignores its `value` after creation - the
  master writes the real token at bootstrap time.
* Cluster Mesh CA IAM access is scoped to the `clustermesh/*` Secrets
  Manager prefix on the `external-secrets` IRSA role, separate from
  `argocd-clusters/*`.
* The shared IRSA OIDC bucket (`modules/oidc-bucket`) is public-read by
  design, but only `s3:GetObject` on the two static discovery documents
  per cluster prefix - never anything sensitive (JWKS is public key
  material only).
* `.tflint.hcl` deliberately disables `terraform_module_pinned_source` -
  every module source is a local path in this monorepo.

---

## Where to look next

* Each module has its own `README.md` with resource tables, variable
  references, and design rationale - read the module's README before
  changing its `main.tf`. **Exception:** `modules/ec2/README.md` is stale
  (pre-IRSA) - trust `modules/ec2/main.tf`/`variables.tf` and this file's
  "IAM model" section over that doc until it's rewritten.
* `packer/README.md` explains exactly what's baked into the AMI vs. what
  stays dynamic.
* `modules/k8s/README.md` has the table of "who owns what" for cluster
  bring-up (kubeadm vs. CI vs. Argo CD) - its CNI details section should
  also be read alongside this file's "ENI IPAM" note above, since it
  predates the `ipam.mode=eni` switch.
* `modules/irsa/README.md` explains the IRSA mechanic and how to onboard a
  new workload onto it.
* `.github/workflows/` - each workflow file's header comment explains why
  it's split the way it is (parallelism, race-freedom on teardown, etc.);
  the tables above summarize but the in-file comments are the source of
  truth for edge cases.