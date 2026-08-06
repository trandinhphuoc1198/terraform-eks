variable "env" { type = string }
variable "vpc_id" { type = string }
variable "vpc_cidr" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "master_instance_type" { type = string }
variable "key_name" { type = string }
variable "cluster_name" { type = string }
variable "master_private_ip" {
  type    = string
  default = null
}

variable "ami_id" {
  description = "AMI ID for the master node - the shared Packer-built k8s base image (see /packer and modules/ami). Replaces the previous dynamic SSM AL2023 lookup."
  type        = string
}

# NOTE: k8s_bootstrap was removed. The master no longer self-bootstraps via
# user_data - kubeadm init/CNI now runs via the k8s-cluster-bootstrap.yml
# CI workflow (SSM send-command), using module.k8s.master_userdata as the
# script content. This makes a failed bootstrap fail a CI job with logs,
# instead of failing silently inside cloud-init on a box nobody's watching.

variable "trusted_api_cidr_blocks" {
  description = <<-EOT
    CIDR blocks allowed to reach the kube-apiserver (port 6443) in addition
    to in-VPC traffic. Used to let the hub cluster's Argo CD reach this
    cluster's API server across the Transit Gateway. Leave empty on the hub
    itself (nothing needs to call *into* the hub's apiserver from a spoke).
  EOT
  type        = list(string)
  default     = []
}

variable "s3_bucket_arns" {
  description = "ARNs of S3 buckets the worker IAM role should be able to read/write. Leave empty (default) if this cluster has no S3-backed workloads - e.g. the hub."
  type        = list(string)
  default     = []
}

variable "register_with_hub" {
  description = "If true, grants this cluster's master role permission to push its own Argo CD registration credentials to Secrets Manager (argocd-clusters/<cluster_name>). Set true on spokes, false on the hub."
  type        = bool
  default     = false
}


variable "master_volume_size" {
  description = "EBS volume size (in GB) for the master node root block device"
  type        = number
  default     = 20
}

variable "vpc_cidr_supernet" {
  description = "Fleet-wide VPC-CIDR supernet (default 10.0.0.0/8). Allowed as an ingress source on the master/worker SGs for WireGuard, clustermesh-apiserver NodePort, and ENI-mode pod-to-pod traffic because pods now carry real VPC IPs."
  type        = string
  default     = "10.0.0.0/8"
}

variable "clustermesh_nodeport" {
  description = "NodePort the clustermesh-apiserver Service listens on - exposed to every other cluster in the fleet for Cilium Cluster Mesh"
  type        = number
  default     = 32379
}

# ── IRSA / OIDC ────────────────────────────────────────────────────────────
variable "oidc_bucket_arn" {
  description = "ARN of the shared IRSA OIDC bucket (modules/oidc-bucket's bucket_arn). If set, grants the master role s3:PutObject scoped to this cluster's own prefix only, so master_init.sh.tpl can publish its OIDC discovery doc + JWKS. Leave \"\" (default) to skip IRSA entirely."
  type        = string
  default     = ""
}

variable "oidc_s3_prefix" {
  description = "This cluster's prefix inside the shared OIDC bucket, e.g. \"hub-dev\" - scopes the master's s3:PutObject grant to only its own cluster's objects. Required if oidc_bucket_arn is set."
  type        = string
  default     = ""
}
