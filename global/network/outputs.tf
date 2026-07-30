output "transit_gateway_id" {
  value = aws_ec2_transit_gateway.main.id
}

output "transit_gateway_default_route_table_id" {
  description = "Default TGW route table ID - used by modules/tgw-attachment to self-register each cluster's own pod CIDR as a static route for Cilium Cluster Mesh"
  value       = aws_ec2_transit_gateway.main.association_default_route_table_id
}