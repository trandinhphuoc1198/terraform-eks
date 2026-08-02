# Attaches this VPC to the shared Transit Gateway created in global/network,
# then adds routes in the given route tables so traffic to the peer
# cluster's CIDR(s) is sent through the TGW.
#
# Note: this module only creates the ATTACHMENT and this VPC's ROUTES.
# The TGW route table association/propagation itself (which controls who
# can reach whom) lives in global/network, since that's shared, blast-radius
# sensitive config that both hub and spoke should not independently manage.

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  transit_gateway_id = var.transit_gateway_id
  vpc_id             = var.vpc_id
  subnet_ids         = var.attachment_subnet_ids

  # Auto-accept is fine here because both attachments are created by the
  # same AWS account. If hub/spoke ever live in different accounts, switch
  # this to a request/accept pair (aws_ec2_transit_gateway_vpc_attachment_accepter).
  transit_gateway_default_route_table_association = true
  transit_gateway_default_route_table_propagation = true

  tags = { Name = "${var.env}-tgw-attachment" }
}

locals {
  route_cidr_pairs = {
    for pair in setproduct(range(length(var.route_table_ids)), var.peer_cidr_blocks) :
    "${pair[0]}|${pair[1]}" => {
      rt_index = pair[0]
      cidr     = pair[1]
    }
  }
}

resource "aws_route" "to_peer" {
  for_each = local.route_cidr_pairs

  route_table_id         = var.route_table_ids[each.value.rt_index]
  destination_cidr_block = each.value.cidr
  transit_gateway_id     = var.transit_gateway_id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

