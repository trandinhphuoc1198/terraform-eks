# ── General ───────────────────────────────────────────────────────────────────
variable "env" {
  description = "Cluster name for this root, e.g. \"spoke-dev\""
  type        = string
}

variable "region" {
  description = "AWS region to deploy this cluster into"
  type        = string
  default     = "ap-northeast-1"
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

# ── EC2 / Master ──────────────────────────────────────────────────────────────
variable "master_instance_type" {
  description = "EC2 instance type for the master node"
  type        = string
}

variable "key_name" {
  description = "EC2 SSH key pair name"
  type        = string
}

variable "master_private_ip" {
  description = "Optional fixed private IP for the master node (e.g. 10.1.1.10); if null, an IP is assigned automatically"
  type        = string
  default     = null
}

variable "master_volume_size" {
  description = "Root EBS volume size in GB for the master node"
  type        = number
  default     = 20
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
variable "k8s_version" {
  description = "Kubernetes minor version (e.g. 1.29)"
  type        = string
  default     = "1.29"
}

variable "pod_cidr" {
  description = "Pod network CIDR passed to kubeadm --pod-network-cidr"
  type        = string
  default     = "192.168.0.0/16"
}


variable "pod_cidr_supernet" {
  description = "Fleet-wide pod-CIDR supernet - var.pod_cidr must fall inside this range for Cilium Cluster Mesh routing to work (see README)"
  type        = string
  default     = "100.64.0.0/10"
}

variable "vpc_cidr_supernet" {
  description = "Fleet-wide VPC-CIDR supernet - lets the clustermesh-apiserver NodePort SG rule admit traffic from any cluster without per-peer rules"
  type        = string
  default     = "10.0.0.0/8"
}

variable "clustermesh_nodeport" {
  description = "NodePort the clustermesh-apiserver Service listens on"
  type        = number
  default     = 32379
}