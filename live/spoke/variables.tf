# ── General ───────────────────────────────────────────────────────────────────
variable "env" {
  description = "Cluster name for this root, e.g. \"spoke-dev\""
  type        = string
}

variable "region" {
  description = "AWS region to deploy this cluster into"
  type        = string
  default     = "us-east-1"
}

variable "network_state_key" {
  description = "S3 key of the global/network state for this environment"
  type        = string
  default     = "global/network/dev/terraform.tfstate"
}

variable "cluster_name" {
  description = "K8s cluster name - must match the ASG discovery tag value"
  type        = string
}

# ── Network ───────────────────────────────────────────────────────────────────
variable "vpc_cidr" {
  description = "CIDR block for this spoke's VPC (e.g. 10.1.0.0/16)"
  type        = string
  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid CIDR block, e.g. 10.1.0.0/16."
  }
}

variable "public_subnet_cidrs" {
  description = "One CIDR per public subnet (must be within vpc_cidr)"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "One CIDR per private subnet (must be within vpc_cidr)"
  type        = list(string)
}

variable "hub_vpc_cidr" {
  description = "CIDR of the hub VPC - used for the TGW route and to allow the hub's Argo CD to reach this cluster's kube-apiserver"
  type        = string
  validation {
    condition     = can(cidrnetmask(var.hub_vpc_cidr))
    error_message = "hub_vpc_cidr must be a valid CIDR block, e.g. 10.0.0.0/16."
  }
}

# ── ASG / Workers ─────────────────────────────────────────────────────────────
variable "worker_instance_type" {
  description = "EC2 instance type for all worker nodes"
  type        = string
}

variable "worker_min" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 1
}

variable "worker_max" {
  description = "Maximum number of worker nodes"
  type        = number
}

variable "worker_desired" {
  description = "Initial desired count of worker nodes (managed by Cluster Autoscaler after first apply)"
  type        = number
}

variable "worker_volume_size" {
  description = "Root EBS volume size in GB for worker nodes"
  type        = number
  default     = 20
}

# ── Kubernetes ────────────────────────────────────────────────────────────────

variable "eks_cluster_version" {
  description = "EKS control-plane Kubernetes version, e.g. \"1.31\". Independent from k8s_version - EKS's supported version list moves on its own schedule."
  type        = string
  default     = "1.31"
}

variable "cilium_version" {
  description = "Cilium helm chart version - installed via Terraform (helm_release), before any node exists"
  type        = string
  default     = "1.20.0"
}

variable "aws_ccm_version" {
  description = "AWS Cloud Controller Manager helm chart version"
  type        = string
  default     = "0.0.11"
}

variable "additional_admin_principal_arns" {
  description = <<-EOT
    IAM principal ARNs (users, roles, or the account root - arn:aws:iam::<account-id>:root)
    to grant cluster-admin EKS access entries on top of the CI role
    (argocd_registration_ci) and the terraform-apply identity (which gets
    admin automatically via bootstrap_cluster_creator_admin_permissions).
    Use this for human/debug access instead of relying on the AWS account
    root principal implicitly - each entry here is explicit, tracked in
    state, and revocable by removing it from the list.
  EOT
  type        = list(string)
  default     = []
}