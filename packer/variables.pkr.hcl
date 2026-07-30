variable "region" {
  type    = string
  default = "ap-northeast-1"
}

variable "k8s_version" {
  description = "Kubernetes minor version to bake into the AMI (e.g. 1.29). Must match modules/k8s's k8s_version for the environment(s) that will consume this AMI."
  type        = string
  default     = "1.29"
}

variable "instance_type" {
  description = "Instance type used only for the build; unrelated to master_instance_type/worker_instance_type"
  type        = string
  default     = "t3.small"
}

variable "subnet_id" {
  description = "Public subnet Packer launches the temporary build instance into (needs internet egress to reach yum/pkgs.k8s.io)"
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "ami_name_prefix" {
  type    = string
  default = "k8s-base"
}

variable "ssh_username" {
  type    = string
  default = "ec2-user"
}
