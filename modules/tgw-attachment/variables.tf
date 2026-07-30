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

variable "tgw_default_route_table_id" {
  description = "Default TGW route table ID (global/network's transit_gateway_default_route_table_id output). Used to register this cluster's own pod CIDR as a static route - self-registered, no coordination with hub or sibling spokes needed."
  type        = string
}

variable "own_pod_cidr" {
  description = "This cluster's own Kubernetes pod CIDR (var.pod_cidr passed to modules/k8s). Registered as a static TGW route pointing at this cluster's own attachment."
  type        = string
}

variable "pod_cidr_supernet" {
  description = "Fleet-wide pod-CIDR supernet reserved for every cluster's pod_cidr (hub + every spoke - see README). Routed to the TGW from this cluster's own route tables so Cilium Cluster Mesh native-routed pod traffic can reach any other cluster without a per-peer route entry."
  type        = string
  default     = "100.64.0.0/10"
}