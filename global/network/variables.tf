variable "region" {
  description = "AWS region to deploy the shared Transit Gateway into"
  type        = string
  default     = "ap-northeast-1"
}

variable "env_prefix" {
  description = "Prefix for naming shared resources, e.g. \"dev\" or \"prod\""
  type        = string
}

variable "amazon_side_asn" {
  description = "ASN for the Amazon side of the Transit Gateway"
  type        = number
  default     = 64512
}
