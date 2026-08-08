variable "env" {
  type = string
}

variable "cluster_name" {
  description = "EKS cluster name this node group joins"
  type        = string
}

variable "node_group_name" {
  description = "Suffix for the node group, e.g. \"platform\" - this repo runs ONE managed node group per cluster for baseline platform pods (ArgoCD, cilium-operator, coredns, cert-manager, external-secrets, etc). Workload pods (fastapi-app, postgresql) run on Karpenter-provisioned nodes instead - see platform/karpenter/spoke."
  type        = string
  default     = "platform"
}

variable "subnet_ids" {
  type = list(string)
}

variable "node_role_arn" {
  description = "IAM role ARN for this node group's instances - created by the caller via modules/eks-node-role, with an EKS access entry already granted for it before this module is instantiated (module-level depends_on at the call site)."
  type        = string
}

variable "instance_types" {
  type    = list(string)
  default = ["m7i-flex.large"]
}

variable "capacity_type" {
  description = "ON_DEMAND or SPOT"
  type        = string
  default     = "ON_DEMAND"
}

variable "ami_type" {
  description = "EKS-optimized AMI family. AL2023_x86_64_STANDARD is the current default recommendation; switch to BOTTLEROCKET_x86_64 if you want an immutable OS."
  type        = string
  default     = "AL2023_x86_64_STANDARD"
}

variable "desired_size" {
  type    = number
  default = 2
}

variable "min_size" {
  type    = number
  default = 2
}

variable "max_size" {
  type    = number
  default = 4
}

variable "disk_size" {
  description = "Root volume size in GB"
  type        = number
  default     = 30
}

variable "labels" {
  description = "Kubernetes node labels - defaults mark these as the baseline/platform pool so platform ArgoCD Applications can nodeSelector onto them explicitly if ever needed (they currently have no such selector and just land here by default, since Karpenter-provisioned nodes carry a workload-tier taint that repels them)."
  type        = map(string)
  default     = {}
}

variable "taints" {
  description = "Node taints. Left empty by default - this is the untainted baseline pool everything schedules onto unless it opts into the Karpenter workload pool via the workload-tier toleration."
  type = list(object({
    key    = string
    value  = string
    effect = string # NO_SCHEDULE | NO_EXECUTE | PREFER_NO_SCHEDULE
  }))
  default = []
}

variable "additional_security_group_ids" {
  type    = list(string)
  default = []
}
