# Looks up the most recent baked k8s base AMI produced by Packer (see
# /packer at the repo root). Replaces the previous per-module dynamic SSM
# lookup of the stock AL2023 AMI, now that containerd/kubeadm/kubelet/
# kubectl/sysctl prep are baked in ahead of time by Ansible instead of
# being installed on every boot.
data "aws_ami" "k8s_base" {
  most_recent = true
  owners      = var.owners

  filter {
    name   = "name"
    values = [var.ami_name_filter]
  }

  filter {
    name   = "tag:purpose"
    values = ["k8s-base"]
  }
}
