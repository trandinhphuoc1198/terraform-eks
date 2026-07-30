# Module: `ec2`

Provisions the **Kubernetes master node** together with all shared IAM and
security group resources that both the master and ASG workers depend on.
The master has no public IP - access is via SSM Session Manager (primary)
or VPC-internal SSH (fallback). The master takes **no `user_data`** -
`kubeadm init` runs later via SSM `send-command` (see `modules/k8s` and the
`k8s-cluster-bootstrap.yml` workflow), not at instance launch.

---

## Resources created

| Resource | Name pattern | Purpose |
|---|---|---|
| `aws_ssm_parameter` | `/${env}/k8s/join_token` | SecureString that holds the kubeadm join command; master writes it, workers read it |
| `aws_security_group` | `${env}-k8s-master-sg` | Master node security group |
| `aws_security_group` | `${env}-k8s-worker-sg` | Worker node security group (used by the ASG module) |
| `aws_vpc_security_group_ingress_rule` / `_egress_rule` | - | Granular inbound/outbound rules for master and worker SGs (see tables below) |
| `aws_iam_role` | `${env}-k8s-master-role` | IAM role for the master EC2 instance |
| `aws_iam_role_policy` | `${env}-k8s-master-ssm-write-policy` | Allows master to `PutParameter` for the join token |
| `aws_iam_role_policy` | `${env}-k8s-master-ccm-policy` | EC2/ELB permissions required by AWS Cloud Controller Manager (incl. route-table management for Cilium native routing) |
| `aws_iam_role_policy` | `${env}-k8s-master-autoscaler-policy` | ASG permissions required by Cluster Autoscaler (runs on master) |
| `aws_iam_role_policy` | `${env}-k8s-master-argocd-registration-policy` | Only if `register_with_hub = true` - lets the master push its own registration secret to Secrets Manager, scoped to `argocd-clusters/<cluster_name>-*` |
| `aws_iam_role_policy` | `${env}-k8s-master-eso-bootstrap-read` | Only if `install_eso = true` - lets the hub master read the ESO bootstrap credentials it just created |
| `aws_iam_role_policy_attachment` | - | Attaches `AmazonSSMManagedInstanceCore` to the master role, unconditionally |
| `aws_iam_instance_profile` | `${env}-k8s-master-profile` | Binds the master IAM role to the EC2 instance |
| `aws_iam_role` | `${env}-k8s-worker-role` | IAM role for worker nodes (used by the ASG Launch Template) |
| `aws_iam_role_policy` | `${env}-k8s-worker-ebs-policy` | EBS volume management for PVCs, S3 access (if `s3_bucket_arns` set), SSM read for join token |
| `aws_iam_role_policy` | `${env}-k8s-worker-clustermesh-ca-push-policy` | Only if `install_clustermesh_ca_push = true` - write access scoped to `clustermesh/*` |
| `aws_iam_role_policy` | `${env}-k8s-worker-clustermesh-ca-pull-policy` | Only if `install_clustermesh_ca_pull = true` - read-only access scoped to `clustermesh/*` |
| `aws_iam_instance_profile` | `${env}-k8s-worker-profile` | Binds the worker IAM role to ASG-launched instances |
| `aws_iam_user` + `aws_iam_access_key` + `aws_iam_user_policy` | `${env}-eso-secrets-reader` | Only if `install_eso = true` - the IAM identity ESO uses to read every spoke's registration secret from `argocd-clusters/*` |
| `aws_secretsmanager_secret` + `_version` | `${env}/eso/bootstrap-credentials` | Only if `install_eso = true` - seeds the above access key for the hub's ESO bootstrap script |
| `aws_instance` | `${env}-k8s-master` | Master EC2 instance in the first **private** subnet - no public IP, no `user_data` |

---

## Accessing the master

SSM Session Manager is the primary access path (works with no public IP, no open SSH, no bastion):

```bash
aws ssm start-session --target <master_instance_id>
```

`master_instance_id` is a module output, also surfaced at `live/hub` /
`live/spoke` root level. This requires the three SSM interface VPC
endpoints provisioned by `modules/vpc` (`ssm`, `ssmmessages`,
`ec2messages`).

SSH (port 22) still works as a fallback, but only from inside the VPC
(`master_ingress_ssh` rule) - not from the public internet.

---

## Security group rules

### Master SG

| Direction | Source | Ports | Reason |
|---|---|---|---|
| Ingress | Worker SG | All | Workers communicate with the API server |
| Ingress | Self | All | Multi-master traffic (future expansion) |
| Ingress | VPC CIDR | TCP 22 | SSH fallback access - VPC-internal only |
| Ingress | each of `trusted_api_cidr_blocks` | TCP 6443 | e.g. lets the hub's Argo CD reach a spoke's apiserver over the TGW |
| Ingress | `pod_cidr_supernet` | All | Cross-cluster pod traffic (Cluster Mesh native routing) - master runs pods too, it isn't cordoned |
| Ingress | `vpc_cidr_supernet` | UDP 51871 | Cilium WireGuard tunnel, fleet-wide |
| Egress | `0.0.0.0/0` | All | Unrestricted outbound |

### Worker SG

| Direction | Source | Ports | Reason |
|---|---|---|---|
| Ingress | Master SG | All | Master-to-worker control plane traffic |
| Ingress | Self | All | Pod-to-pod and inter-worker traffic |
| Ingress | VPC CIDR | TCP 22 | SSH from within the VPC only |
| Ingress | `pod_cidr_supernet` | All | Cross-cluster pod traffic (Cluster Mesh native routing) |
| Ingress | `vpc_cidr_supernet` | UDP 51871 | Cilium WireGuard tunnel, fleet-wide |
| Ingress | `vpc_cidr_supernet` | TCP `clustermesh_nodeport` | `clustermesh-apiserver` NodePort, reachable from every cluster in the fleet |
| Egress | `0.0.0.0/0` | All | Unrestricted outbound (yum, image pulls via NAT) |

> **No ALB ingress rule exists today.** There is currently no rule
> admitting traffic from an ALB security group into the worker `NodePort`
> range - `modules/alb` isn't instantiated by any `live/*` root (see the
> root README's "Ingress note"). Add one back if you re-wire an ALB.

> Security group rules are managed as separate split-resource types
> (`aws_vpc_security_group_ingress_rule` / `_egress_rule`). The
> `aws_security_group` resources themselves use
> `lifecycle { ignore_changes = [ingress, egress] }` to prevent Terraform
> from removing rules added by external controllers (e.g. AWS CCM
> provisioning a LoadBalancer-type Service).

---

## IAM permissions detail

### Master role

**SSM write** - `ssm:PutParameter` scoped to the join token parameter ARN only.

**SSM managed instance core** - `AmazonSSMManagedInstanceCore`, attached
unconditionally to every master.

**Cloud Controller Manager (CCM)** - EC2 describe/tag/route-table
permissions (route management is scoped to resources tagged
`kubernetes.io/cluster/<cluster_name>=owned`, needed for Cilium native
routing) plus broad ELB permissions matching AWS's documented
`cloud-provider-aws` policy.

**Cluster Autoscaler** - ASG describe and scale permissions, scale actions
scoped to the ASG tagged for this cluster.

**Argo CD registration push** (`register_with_hub = true`, spoke only) -
write access to `argocd-clusters/<cluster_name>-*` in Secrets Manager only.

**ESO bootstrap credentials read** (`install_eso = true`, hub only) - read
access to the one Secrets Manager entry seeding the hub's ESO `aws-creds`.

### Worker role

**EBS (for PVCs)** - create/attach/detach/delete volumes and snapshots,
scoped by request/resource tags (`ebs.csi.aws.com/cluster=true` on
volumes/snapshots, `kubernetes.io/cluster/<cluster_name>=owned` on
instances for attach/detach).

**S3** (only if `s3_bucket_arns` is non-empty) - `GetObject`, `PutObject`,
`DeleteObject`, `ListBucket` scoped to the given bucket ARNs.

**SSM read** - `ssm:GetParameter` scoped to the join token parameter ARN only.

**Cluster Mesh CA push** (`install_clustermesh_ca_push = true`, hub only) -
`CreateSecret`/`PutSecretValue`/`DescribeSecret`/`TagResource`/`GetSecretValue`
scoped to `clustermesh/*`.

**Cluster Mesh CA pull** (`install_clustermesh_ca_pull = true`, spoke only)
- `GetSecretValue`/`DescribeSecret` scoped to `clustermesh/*`.

Both roles are granted the Cluster Mesh CA policies (not just one) because
the ESO controller pod that actually calls Secrets Manager can land on
either the master or a worker - Terraform can't predict scheduling.

---

## AMI selection

Both master and worker use the shared Packer-built k8s base AMI
(containerd/kubeadm/kubelet/kubectl baked in) - see `/packer` and
`modules/ami`.

---

## Variables

| Name | Type | Default | Description |
|---|---|---|---|
| `env` | `string` | - | Environment name - prefix for all resource names and SSM path |
| `vpc_id` | `string` | - | VPC ID (from `vpc` module output) |
| `vpc_cidr` | `string` | - | VPC CIDR - scopes the master/worker SSH ingress rules to VPC-internal only |
| `private_subnet_ids` | `list(string)` | - | Private subnet IDs - master is placed in `[0]` |
| `master_instance_type` | `string` | - | EC2 instance type for the master node |
| `key_name` | `string` | - | EC2 SSH key pair name |
| `master_private_ip` | `string` | `null` | Optional fixed private IP for the master node; if `null`, assigned automatically |
| `master_volume_size` | `number` | `20` | Root EBS volume size in GB for the master node |
| `cluster_name` | `string` | - | Kubernetes cluster name - applied as tags for CCM/Cluster Autoscaler discovery |
| `ami_id` | `string` | - | Shared Packer-built k8s base AMI ID (from `modules/ami`) |
| `trusted_api_cidr_blocks` | `list(string)` | `[]` | CIDRs allowed to reach port 6443 in addition to in-VPC traffic (e.g. hub reaching a spoke's apiserver) |
| `s3_bucket_arns` | `list(string)` | `[]` | Bucket ARNs the worker role can access |
| `register_with_hub` | `bool` | `false` | Grants the master role permission to push its own Argo CD registration secret - spokes only |
| `install_eso` | `bool` | `false` | Provisions the ESO reader IAM identity and related resources - hub only |
| `install_clustermesh_ca_push` | `bool` | `false` | Grants master + worker roles write access to `clustermesh/*` - hub only |
| `install_clustermesh_ca_pull` | `bool` | `false` | Grants master + worker roles read access to `clustermesh/*` - spoke only |
| `pod_cidr_supernet` | `string` | `100.64.0.0/10` | Fleet-wide pod-CIDR supernet, allowed as an SG ingress source so Cluster Mesh pod traffic isn't dropped at the node ENI |
| `vpc_cidr_supernet` | `string` | `10.0.0.0/8` | Fleet-wide VPC-CIDR supernet, allowed as an SG ingress source for WireGuard and the clustermesh-apiserver NodePort |
| `clustermesh_nodeport` | `number` | `32379` | NodePort the `clustermesh-apiserver` Service listens on |

---

## Outputs

| Name | Description |
|---|---|
| `master_instance_id` | EC2 instance ID of the master - target for `aws ssm start-session` |
| `master_private_ip` | Private IP of the master - used by workers in `kubeadm join` |
| `master_sg_id` | Security group ID of the master |
| `worker_sg_id` | Worker security group ID - passed to the `asg` module |
| `worker_iam_instance_profile_name` | Worker instance profile name - passed to the `asg` Launch Template |
| `ssm_join_token_arn` | ARN of the join token SSM parameter |
| `master_instance_arn` | ARN of the master instance - used to scope the CI role's `ssm:SendCommand` permission |
