# Module: `ami`

Looks up the most recent Packer-built k8s base AMI (see `/packer` at the
repo root) and outputs its ID. One AMI is shared by both the master node
(`modules/ec2`) and the worker Auto Scaling Group (`modules/asg`) - same
pattern as the single AL2023 AMI they both resolved before this change,
except now it's a custom image with containerd/kubeadm/kubelet/kubectl and
node prep baked in via Ansible instead of installed at every boot.

---

## Resources created

| Resource | Purpose |
|---|---|
| `aws_ami` (data source) | Finds the newest AMI tagged `purpose = k8s-base` matching the name filter |

---

## Variables

| Name | Type | Default | Description |
|---|---|---|---|
| `ami_name_filter` | `string` | `"k8s-base-*"` | Wildcard match against the AMI name Packer assigns |
| `owners` | `list(string)` | `["self"]` | AMI owner account(s) to search |

---

## Outputs

| Name | Description |
|---|---|
| `ami_id` | ID of the most recent baked k8s base AMI |

---

## Usage

```hcl
module "ami" {
  source = "./modules/ami"
}

module "ec2" {
  source = "./modules/ec2"
  ami_id = module.ami.ami_id
  # ...
}

module "asg" {
  source = "./modules/asg"
  ami_id = module.ami.ami_id
  # ...
}
```
