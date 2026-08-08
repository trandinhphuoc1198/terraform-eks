variable "env" {
  type = string
}

variable "role_name" {
  description = "Suffix identifying which pool this role is for, e.g. \"platform\" or \"karpenter\""
  type        = string
}
