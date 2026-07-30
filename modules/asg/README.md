# Module: `asg`

Provisions the **worker node pool** - an EC2 Launch Template and Auto Scaling Group that runs Kubernetes worker nodes in private subnets. The ASG is tagged for discovery by both the AWS Cloud Controller Manager and Cluster Autoscaler.

---

## Resources created

| Resource | Name pattern | Purpose |
|---|---|---|
| `aws_launch_template` | `${env}-k8s-worker-lt` | Defines instance type, AMI, IAM profile, user_data, and volume config for all workers |
| `aws_autoscaling_group` | `${env}-k8s-workers` | Manages the fleet of worker nodes across private subnets |

---

## Design notes

### Cluster Autoscaler integration

The ASG carries two tags that Cluster Autoscaler uses for auto-discovery:

```
k8s.io/cluster-autoscaler/enabled              = "true"
k8s.io/cluster-autoscaler/${cluster_name}      = "owned"
```

These tags must match the `--node-group-auto-discovery` argument in the Cluster Autoscaler pod spec. After the first `terraform apply`, `desired_capacity` is managed by the Cluster Autoscaler - Terraform is told to ignore changes to it:

```hcl
lifecycle {
  ignore_changes = [desired_capacity]
}
```

This prevents Terraform from reverting the autoscaler's scaling decisions on subsequent applies.

### No ALB target registration today

There is currently no `aws_autoscaling_attachment` wiring this ASG to an
ALB target group - `modules/alb` exists in the repo but isn't instantiated
by `live/hub` or `live/spoke` (see the root README's "Ingress note"). If
you re-add an ALB in front of a cluster, you'll need to add both the
attachment here and the corresponding worker security-group ingress rule
in `modules/ec2` (also currently absent).

### IMDSv2 enforcement

The Launch Template sets `http_tokens = "required"` to enforce IMDSv2 on all worker instances. The worker bootstrap script retrieves region, AZ, and instance ID via IMDSv2 to construct the `provider-id` for the AWS CCM.

### AMI

Workers use the shared Packer-built k8s base AMI (see `/packer` and
`modules/ami`), resolved once per apply and shared with the master
(`modules/ec2`) - not a dynamic per-boot SSM lookup.

### EBS volume

Each worker gets a single root gp3 EBS volume. Volume size is configurable via `worker_volume_size` (default 20 GB). `delete_on_termination = true` ensures no orphaned volumes are left behind when the ASG scales in.

### Instance refresh

`instance_refresh { strategy = "Rolling" }` rolls existing workers when the
launch template changes - including when a new Packer-built AMI shows up
via `modules/ami` - no manual drain/terminate needed.

### Worker bootstrap

`k8s_worker_bootstrap` (from `modules/k8s`'s `worker_userdata` output)
polls SSM for the join token pushed by the master, then runs `kubeadm
join`. It does not itself configure any Service NodePorts - NodePort
Services/Ingress are a Kubernetes-level concern deployed later by Argo CD,
independent of this Terraform module.

---

## Variables

| Name | Type | Default | Description |
|---|---|---|---|
| `env` | `string` | - | Environment name - prefix for resource names and ASG tags |
| `worker_instance_type` | `string` | - | EC2 instance type for all worker nodes |
| `key_name` | `string` | - | EC2 SSH key pair name |
| `private_subnet_ids` | `list(string)` | - | Private subnets the ASG distributes workers across |
| `worker_sg_id` | `string` | - | Security group ID applied to all worker instances (from `ec2` module) |
| `worker_iam_instance_profile_name` | `string` | - | IAM instance profile for workers (from `ec2` module) |
| `k8s_worker_bootstrap` | `string` | - | Worker `user_data` script (from `k8s` module output) |
| `ami_id` | `string` | - | Shared Packer-built k8s base AMI ID (from `modules/ami`) |
| `worker_min` | `number` | `1` | Minimum number of worker nodes |
| `worker_max` | `number` | `10` | Maximum number of worker nodes |
| `worker_desired` | `number` | `2` | Initial desired count (managed by Cluster Autoscaler after first apply) |
| `worker_volume_size` | `number` | `20` | Root EBS volume size in GB |
| `cluster_name` | `string` | - | Kubernetes cluster name - embedded in ASG auto-discovery tags |

---

## Outputs

| Name | Description |
|---|---|
| `asg_name` | Name of the Auto Scaling Group - useful as input to Cluster Autoscaler Helm values |
| `launch_template_id` | ID of the worker Launch Template |
