# Shared Transit Gateway connecting the hub cluster's VPC to every spoke
# cluster's VPC. This lives in its own state because it's a shared resource
# that neither hub nor spoke should be able to destroy/recreate as a side
# effect of an unrelated change in their own root module.
#
# Apply this FIRST, before live/hub or live/spoke - both of those read its
# transit_gateway_id via a terraform_remote_state data source.

resource "aws_ec2_transit_gateway" "main" {
  description                     = "Hub-spoke TGW for ${var.env_prefix} Kubernetes clusters"
  amazon_side_asn                 = var.amazon_side_asn
  auto_accept_shared_attachments  = "disable"
  default_route_table_association = "enable"
  default_route_table_propagation = "enable"

  tags = { Name = "${var.env_prefix}-k8s-tgw" }
}
