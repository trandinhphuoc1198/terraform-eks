# Packer: k8s base AMI

Builds the shared AMI used by **both** the master node (`modules/ec2`) and
worker nodes (`modules/asg`) in every environment (hub and every spoke).

## What's baked in vs. what stays dynamic

| Baked into the AMI (this Packer build) | Stays dynamic, but moved out of Terraform (this repo's Phase 1–4 refactor) |
|---|---|
| swap disabled, kernel modules, sysctl | `kubeadm init` / `kubeadm join` - now CI-driven via SSM, not `user_data`, for master (worker stays `user_data`, see modules/k8s/README.md) |
| containerd (SystemdCgroup=true) | CNI manifest apply |
| kubeadm, kubelet, kubectl | AWS CCM, Argo CD, ESO installs - now Argo CD `ApplicationSet`s / one-time CI steps, not Terraform |
| kubelet enabled | join-token SSM read/write |

The runtime pieces stay dynamic because they're per-instance (provider-id,
private IP) or depend on coordination between the master and workers at
launch time - they can't be baked in ahead of time.

## Build

```bash
cd packer
packer init .
packer build \
  -var="subnet_id=<a public subnet with internet egress>" \
  -var="vpc_id=<vpc id>" \
  -var="k8s_version=1.29" \
  .
```

Requires `ansible-playbook` installed locally - Packer's `ansible`
provisioner runs it over SSH against the temporary build instance, it does
not need to be pre-installed on the AMI itself.

`k8s_version` must match the `k8s_version` variable passed to the `k8s`
Terraform module for any environment that will use this AMI (it controls
which Kubernetes yum repo is baked in).

## How Terraform finds the result

The build tags the AMI `purpose = "k8s-base"` and names it
`k8s-base-k8s<version>-<timestamp>`. `modules/ami` looks it up with
`most_recent = true`, so a fresh `terraform apply` automatically picks up
the newest successful build - no AMI ID to copy/paste into tfvars.

## Rollout notes

- Because both `modules/ec2` and `modules/asg` now take `ami_id` from the
  same `modules/ami` lookup, a new AMI build affects the master **and**
  new worker launches together on the next `apply`.
- The ASG's existing `instance_refresh` block (see `modules/asg/main.tf`)
  performs a rolling replacement of running workers when the launch
  template's AMI changes - no manual drain/terminate needed.
- The master is a single `aws_instance`, not in an ASG - replacing it on
  AMI change requires a manual `terraform apply` + rejoin/verify, same as
  before this change (this was already true when the AMI came from the
  SSM lookup).

