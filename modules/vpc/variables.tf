variable "env" { type = string }
variable "vpc_cidr" { type = string }
variable "public_subnet_cidrs" { type = list(string) }
variable "private_subnet_cidrs" { type = list(string) }
variable "region" { type = string }

variable "cluster_name" {
  description = "K8s cluster name - tags the private route table with kubernetes.io/cluster/<cluster_name> so AWS Cloud Controller Manager's route controller (--configure-cloud-routes=true) can discover it for native-routing pod-CIDR sync. Same tag/value convention already used on ASG/instance resources in modules/ec2 and modules/asg."
  type        = string
}

