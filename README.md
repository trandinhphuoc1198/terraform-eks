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
              │  VPC 10.0.0.0/16       │◄──┤  VPC 10.1.0.0/16       │
              │  runs: Argo CD (GitOps)│TGW│  runs: app workloads   │
              │  pod CIDR 100.64.0.0/16│   │  pod CIDR 100.65.0.0/16│
              └────────────────────────┘   └────────────────────────┘
                          │  Cilium Cluster Mesh (WireGuard, native routing) │
                          └──────────────────── over the same TGW ──────────┘
```

* **`global/network`** - a shared Transit Gateway (TGW). Applied once,
  independently, before hub or spoke. Neither hub nor spoke can
  accidentally destroy/recreate it as a side effect of their own changes.
* **`live/hub`** - one Kubernetes cluster whose only real job is to run
  **Argo CD**, the GitOps controller for the whole fleet.
* **`live/spoke`** - one Kubernetes cluster that runs actual application
  workloads. Additional spokes are added by copying this root (e.g.
  `live/spoke-2`) - see "Adding a second spoke" below.
* Hub and spoke VPCs are connected through the shared TGW so the hub's
  Argo CD can reach each spoke's `kube-apiserver` directly (pull-based
  GitOps against every registered cluster), and so pod traffic between
  clusters can be natively routed for Cilium Cluster Mesh.

Both `live/hub` and `live/spoke` are structurally near-identical roots
(vpc → tgw-attachment → ami → k8s scripts → ec2 master → asg workers → s3),
differing mainly in a few module flags (`install_eso` vs. `register_with_hub`,
`install_clustermesh_ca_push` vs. `install_clustermesh_ca_pull`,
`trusted_api_cidr_blocks`, whether S3 buckets exist).

**Ingress note:** `modules/alb` and `modules/acm` exist in this repo but
**neither `live/hub` nor `live/spoke` currently instantiates them** - no
`module "alb"` / `module "acm"` block exists in either root's `main.tf`.
Treat those two modules as reserved/legacy for now. Application ingress
today happens inside the cluster (NGINX Ingress via Argo CD, forwarding to
the worker `NodePort` range), fronted by whatever you point at the worker
nodes directly - there is no Terraform-managed internet-facing load
balancer at the moment. If you re-wire an ALB in front of a cluster, you
will also need to re-add a security-group rule admitting the ALB's traffic
into the worker `NodePort` range - the current `modules/ec2` worker
security group does **not** have one.

---

## Repo layout

```
global/network/          Shared Transit Gateway - its own state, apply first
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
| [`vpc`](modules/vpc/README.md) | VPC, public/private subnets, a NAT **Gateway** (AWS-managed, not an EC2 instance), S3 gateway endpoint, SSM interface endpoints | Yes |
| [`ami`](modules/ami/README.md) | Looks up the newest Packer-built k8s base AMI (`purpose=k8s-base` tag) | Yes |
| [`ec2`](modules/ec2/README.md) | Master node + all shared IAM roles/security groups for master and workers, incl. Cluster Mesh SG rules and CA push/pull IAM | Yes |
| [`asg`](modules/asg/README.md) | Worker Launch Template + Auto Scaling Group, tagged for Cluster Autoscaler discovery | Yes |
| [`tgw-attachment`](modules/tgw-attachment) | Attaches a cluster's VPC to the shared TGW, adds peer routes, and self-registers the cluster's pod CIDR + the fleet pod-CIDR supernet for Cluster Mesh | Yes |
| [`k8s`](modules/k8s/README.md) | Renders `master_userdata` / `worker_userdata` bootstrap scripts (content only - doesn't attach or run anything) | Yes |
| [`s3`](modules/s3/README.md) | Application/cluster S3 buckets | Spoke only |
| [`alb`](modules/alb) | Internet-facing ALB, per-app target groups, host-based HTTPS routing to the NodePort | **Not instantiated** - present but unused |
| [`acm`](modules/acm/README.md) | ACM certificate for an ALB's HTTPS listener | **Not instantiated** - present but unused |

---

## What's baked into the AMI vs. what runs at bootstrap time

Node bring-up is split across three layers:

| Layer | What it does | When it runs | Where it lives |
|---|---|---|---|
| **Packer + Ansible** (`/packer`) | swap off, kernel modules, sysctl, containerd, kubeadm/kubelet/kubectl install, Helm install, disable-source-dest-check unit | Once, ahead of time, produces an AMI | `packer/ansible/playbook.yml` |
| **`user_data` / CI script** | `kubeadm init` or `kubeadm join`, Cilium CNI (Helm, native routing + WireGuard), AWS CCM | At node launch / cluster bootstrap | `modules/k8s/templates/*.tpl` |
| **Argo CD (GitOps)** | Everything else: CCM upgrades on spokes, External Secrets Operator, application workloads, Cluster Mesh CA distribution | Continuously, reconciling from Git | separate `gitops` repo (referenced by raw URL) |

* **AMI baking** removes repeated package installs from every boot.
* `kubeadm init` runs via `k8s-cluster-bootstrap.yml` (SSM `send-command`),
  not master `user_data` - a failed bootstrap shows up as a failed GitHub
  Actions job with logs.
* Workers still run `kubeadm join` from `user_data` at launch time (Cluster
  Autoscaler scale-out has no CI trigger to hook into), polling SSM for the
  join token (`modules/k8s/templates/worker_init.sh.tpl`).
* CNI (Cilium) is installed via `helm upgrade --install` directly inside
  `master_init.sh.tpl` when `install_cni_ccm = true` (hub) - **not** a
  static manifest apply. `routingMode=native`, `ipam.mode=kubernetes`,
  and `encryption.type=wireguard` are set so cross-cluster pod traffic is
  natively routed and encrypted over the TGW. Spokes set
  `install_cni_ccm = false`; Argo CD's own `ApplicationSet` installs
  Cilium + AWS CCM on a spoke once it registers.
* AWS CCM is installed the same way, unconditionally, on every cluster -
  every node carries the
  `node.cloudprovider.kubernetes.io/uninitialized:NoSchedule` taint from
  `cloud-provider=external` until CCM clears it, and that has to happen
  before anything (including Argo CD's own pods) can schedule.

---

## Cluster Mesh (cross-cluster pod networking)

Every cluster carves its pod CIDR out of a shared, fleet-wide supernet
(`pod_cidr_supernet`, default `100.64.0.0/10`) and self-registers a static
TGW route for its own pod CIDR (`modules/tgw-attachment`). Each cluster
also routes the entire supernet to the TGW from its own route tables, so
any pod IP outside its own pod CIDR is forwarded to whichever cluster owns
it - no per-peer route maintenance when adding a spoke.

Traffic is re-encapsulated as WireGuard (`cilium_wg0`, UDP/51871) between
real node IPs for cross-cluster encryption; the `clustermesh-apiserver`
Service is exposed on a fixed `NodePort` (`clustermesh_nodeport`, default
`32379`) reachable from any cluster in the fleet's VPC-CIDR supernet
(`vpc_cidr_supernet`, default `10.0.0.0/8`). The CA used by Cluster Mesh is
pushed by the hub (`install_clustermesh_ca_push`) and pulled by each spoke
(`install_clustermesh_ca_pull`) via External Secrets Operator, using a
dedicated `clustermesh/*` IAM scope on both the master and worker roles
(see `modules/ec2/main.tf`).

`live/hub/main.tf` and `live/spoke/main.tf` both run a `check` block that
converts `pod_cidr`/`pod_cidr_supernet`/every relevant VPC CIDR to numeric
ranges and asserts no overlaps and that `pod_cidr` falls inside
`pod_cidr_supernet` - this catches a bad CIDR at `terraform plan` time
instead of deep inside a failed TGW route apply.

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
3. **On the hub**, External Secrets Operator (seeded via
   `bootstrap-eso-secret.sh.tpl`'s `aws-creds` Secret) reads that path and
   materializes a Kubernetes `Secret` labeled
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
  assert VPC CIDRs and pod CIDRs don't overlap, and that `pod_cidr` sits
  inside `pod_cidr_supernet` (see Cluster Mesh section above).
* **No Terraform-managed internet-facing load balancer today** - see the
  "Ingress note" in the Architecture section above.

---

## Apply order (first-time bring-up)

```
1. global/network   (shared TGW - must exist before hub or spoke)
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

1. Copy `live/spoke` → `live/spoke-2` (new backend key, new `vpc_cidr` and
   `pod_cidr` disjoint from every other cluster, new
   `envs/<env>/terraform.tfvars`).
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

| Workflow | Scope |
|---|---|
| `k8s-deregister-from-hub.yml` | Spoke only - temporarily removes the spoke from ArgoCD's live inventory (deletes `root-clusters` with `cascade=orphan`, then the spoke's `ExternalSecret`/`Secret`, then every generated Application in reverse sync-wave order except node-critical infra) so nothing can resurrect a workload while draining runs. Not tolerant of failure. |
| `drain-cluster.yml` | Deletes every `type=LoadBalancer` Service (so CCM removes its NLB/ALB/Classic ELB) and every namespace that owns a PVC (so the CSI driver issues `DeleteVolume`), before that cluster's infra is torn down. Best-effort - logs a warning rather than failing. Optionally freezes the local Argo CD controllers first (`freeze_argocd_namespace`, used on the hub). |
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
is what actually releases those.

---

## State & backend

All roots use an **S3 backend** with **S3 native locking**
(`use_lockfile = true` - no DynamoDB table required), bucket
`terraform-state-phuoctd6`, region `ap-northeast-1`. Each root's `key` is
supplied at `terraform init` time via `-backend-config=envs/<env>/backend.hcl`
so `backend.tf` itself stays identical across environments:

| Root | State key |
|---|---|
| `global/network` | `global/network/<env>/terraform.tfstate` |
| `live/hub` | `hub/<env>/terraform.tfstate` |
| `live/spoke` | `spoke/<env>/terraform.tfstate` |

`live/hub` and `live/spoke` each read `global/network`'s state via
`terraform_remote_state` (one-directional).

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
* The worker IAM role's S3 policy (`modules/ec2`) is scoped to
  `s3_bucket_arns` when non-empty, otherwise omitted entirely - the hub
  passes none.
* The join-token SSM parameter (`/<env>/k8s/join_token`) is a
  `SecureString`; Terraform ignores its `value` after creation - the
  master writes the real token at bootstrap time.
* Cluster Mesh CA IAM access (`install_clustermesh_ca_push` /
  `install_clustermesh_ca_pull`) is scoped to the `clustermesh/*` Secrets
  Manager prefix only, separate from `argocd-clusters/*`.
* `.tflint.hcl` deliberately disables `terraform_module_pinned_source` -
  every module source is a local path in this monorepo.

---

## Where to look next

* Each module has its own `README.md` with resource tables, variable
  references, and design rationale - read the module's README before
  changing its `main.tf`.
* `packer/README.md` explains exactly what's baked into the AMI vs. what
  stays dynamic.
* `modules/k8s/README.md` has the full table of "who owns what" for
  cluster bring-up (kubeadm vs. CI vs. Argo CD).
* `.github/workflows/` - each workflow file's header comment explains why
  it's split the way it is (parallelism, race-freedom on teardown, etc.);
  the tables above summarize but the in-file comments are the source of
  truth for edge cases.
