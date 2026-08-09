variable "env" {
  description = "Environment/cluster name, e.g. \"hub-dev\" or \"spoke-dev\""
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name - kept as a separate var from env for parity with the pre-EKS modules, which used cluster_name for k8s-level tagging (ASG discovery, CCM route tags) distinct from env"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes minor version for the EKS control plane, e.g. \"1.31\". Must be a version EKS currently supports - check `aws eks describe-addon-versions` / AWS release notes before bumping."
  type        = string
  default     = "1.31"
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  description = "Private subnets - control plane ENIs and all nodes live here"
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnets, only needed if endpoint_public_access requires them or you want internet-facing NLBs in the same subnets. Safe to leave empty for a private-node/private-subnet-only cluster."
  type        = list(string)
  default     = []
}

variable "endpoint_private_access" {
  description = "Allow the API server to be reached from inside the VPC (and, via TGW, from a peered cluster's VPC). Should stay true - this is how the hub's ArgoCD reaches a spoke's apiserver, replacing the old trusted_api_cidr_blocks SG rule on the kubeadm master."
  type        = bool
  default     = true
}

variable "endpoint_public_access" {
  description = "Allow the API server to be reached from the public internet. Needed for GitHub-hosted Actions runners to run kubectl/helm against the cluster directly (no more SSM send-command tunnel). Restrict with public_access_cidrs rather than disabling outright, since a private-only endpoint requires self-hosted runners inside the VPC."
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public endpoint when endpoint_public_access = true. Defaults wide open - TIGHTEN this (e.g. to your office/VPN CIDR + accept that CI needs GitHub's dynamic ranges, which argues for an IAM-only trust model instead of CIDR restriction for the CI path)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "trusted_api_cidr_blocks" {
  description = "Additional CIDRs (beyond the VPC itself) allowed to reach the API server on 443 via the cluster's additional security group - e.g. a peer cluster's VPC CIDR reachable over TGW. Mirrors modules/ec2's old trusted_api_cidr_blocks."
  type        = list(string)
  default     = []
}

variable "clustermesh_trusted_cidr_blocks" {
  description = "Peer cluster VPC CIDR(s) allowed to reach this cluster's nodes for Cilium Cluster Mesh - WireGuard (UDP 51871) and the clustermesh-apiserver NodePort (TCP 32379). Mirrors modules/ec2's old vpc_cidr_supernet SG rule."
  type        = list(string)
  default     = []
}

variable "clustermesh_nodeport" {
  description = "NodePort clustermesh-apiserver is exposed on"
  type        = number
  default     = 32379
}

variable "enable_karpenter_discovery" {
  description = "Tags private subnets with karpenter.sh/discovery=<cluster_name>. false on the hub, since it no longer runs Karpenter."
  type        = bool
  default     = true
}