# Module: `k8s`

Renders the two bootstrap scripts used to bring a kubeadm cluster's nodes up - `master_userdata` and `worker_userdata`. This module produces **script content only**; it does not run anything or attach `user_data` to any instance itself.

---

## Scope (deliberately narrow)

This module's only job is "get kubeadm to a Ready node with CNI installed." It does **not** install Argo CD or External Secrets Operator, and does not handle hub cluster registration. Those moved to CI workflows and, past Argo CD's own install, to Argo CD itself:

| Concern | Where it lives now |
|---|---|
| kubeadm init/join | This module's templates, run via `.github/workflows/k8s-cluster-bootstrap.yml` (SSM send-command) for the master - the only piece still consumed as `worker_userdata` set directly as ASG `user_data`, since worker scale-out has no CI trigger to hook into |
| CNI (Cilium) + AWS CCM | Installed by `master_init.sh.tpl` via `helm upgrade --install` when `install_cni_ccm = true` (hub); on spokes (`install_cni_ccm = false`), Argo CD's own `ApplicationSet` installs Cilium + CCM after the spoke registers |
| Argo CD itself | `.github/workflows/k8s-bootstrap-argocd.yml`, hub only, one-time |
| External Secrets Operator | Argo CD `ApplicationSet` in the gitops repo |
| `aws-creds` Secret for ESO | `.github/workflows/k8s-bootstrap-argocd.yml` |
| Hub cluster registration (token push + rotation) | `.github/workflows/k8s-register-with-hub.yml` (spoke only) |
| Cluster Mesh CA distribution | ESO `PushSecret`/`ExternalSecret` (`platform/clustermesh/**` in the gitops repo), backed by IAM granted in `modules/ec2` |

Why: Terraform can't track state for imperative install steps (no diff, no
rollback), and anything that's an ordinary Kubernetes resource belongs in
Argo CD's reconciliation loop, not a shell script embedded in a Terraform
template.

---

## CNI details (when `install_cni_ccm = true`)

`master_init.sh.tpl` installs Cilium via `helm upgrade --install
cilium cilium/cilium --version 1.16.0`, with (among other settings):

* `routingMode=native`, `autoDirectNodeRoutes=false`,
  `ipv4NativeRoutingCIDR=${pod_cidr_supernet}` - cross-node pod routing
  relies on AWS CCM's route controller keeping the VPC route table in sync
  with each node's `podCIDR`, since nodes aren't L2-adjacent across AZs.
* `ipam.mode=kubernetes`, `ipam.operator.clusterPoolIPv4PodCIDRList=${pod_cidr}`.
* `encryption.enabled=true`, `encryption.type=wireguard` - encrypts
  inter-node pod traffic, including cross-cluster Cluster Mesh traffic.
* `kubeProxyReplacement=true`, `nodePort.range="30000,32767"`.

This is retried up to 5 times (10s backoff) since Helm installs can race a
still-settling apiserver. AWS CCM is then installed unconditionally
(regardless of `install_cni_ccm`) with `--configure-cloud-routes=true
--cluster-cidr=${pod_cidr}`, and the script waits for the
`node.cloudprovider.kubernetes.io/uninitialized` taint to clear and the
node to reach `Ready`.

When `install_cni_ccm = false` (spokes), both the CNI and CCM install
blocks are skipped and logged - the node stays `NotReady` and tainted
until Argo CD's own `ApplicationSet` installs Cilium + CCM after this
spoke pushes its registration secret.

---

## Outputs

| Name | Description |
|---|---|
| `master_userdata` | kubeadm init + CNI/CCM script content. **Not** attached as `user_data` - consumed by `k8s-cluster-bootstrap.yml` via `terraform output -raw master_userdata`, pushed to the instance over SSM send-command. |
| `worker_userdata` | kubeadm join script content. Attached directly as the ASG launch template's `user_data` (`modules/asg`) - this one stays boot-time, since new workers bootstrap unattended on scale-out. |

---

## Variables

| Name | Type | Default | Description |
|---|---|---|---|
| `k8s_version` | `string` | - | Kubernetes minor version (e.g. `1.29`) |
| `pod_cidr` | `string` | - | This cluster's pod network CIDR, passed to kubeadm's cluster config and to Cilium's IPAM pool |
| `env` | `string` | - | Target environment/cluster name (e.g. `hub-dev`, `spoke-dev`) |
| `pod_cidr_supernet` | `string` | `100.64.0.0/10` | Fleet-wide pod-CIDR supernet (see root README's Cluster Mesh section) - sets Cilium's `ipv4NativeRoutingCIDR` so cross-cluster pod traffic isn't masqueraded |
| `install_cni_ccm` | `bool` | `true` | If `true`, the master bootstrap script installs Cilium + AWS CCM directly and waits for the node to become Ready. `true` for the hub (Argo CD needs a working pod network + cleared taint before it can run, so it can't outsource its own CNI/CCM to itself). `false` for spokes - Argo CD installs CNI/CCM after registration instead. |
