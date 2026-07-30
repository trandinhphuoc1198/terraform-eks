variable "ami_name_filter" {
  description = "Wildcard name filter for the baked k8s base AMI (Packer names it k8s-base-k8s<version>-<timestamp>)"
  type        = string
  default     = "k8s-base-*"
}

variable "owners" {
  description = "AMI owner account ID(s) to search. Defaults to \"self\" since Packer builds the AMI into this same AWS account."
  type        = list(string)
  default     = ["self"]
}
