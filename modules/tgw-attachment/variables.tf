variable "env" {
  description = "Environment/cluster name, used for resource naming (e.g. \"hub-dev\", \"spoke-dev\")"
  type        = string
}

variable "transit_gateway_id" {
  description = "ID of the shared Transit Gateway (from the global/network root)"
  type        = string
}

variable "vpc_id" {
  type = string
}

# Attachment subnets should be private subnets, one per AZ you want the
# attachment to have an ENI in. Two is normally enough for HA.
variable "attachment_subnet_ids" {
  type = list(string)
}

# Route tables in THIS vpc that need a route toward the peer CIDR(s).
variable "route_table_ids" {
  type = list(string)
}

# CIDR block(s) of the peer cluster's VPC(s) reachable through the TGW.
variable "peer_cidr_blocks" {
  type = list(string)
}

