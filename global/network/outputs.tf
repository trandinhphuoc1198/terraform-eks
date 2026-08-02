output "transit_gateway_id" {
  value = aws_ec2_transit_gateway.main.id
}

output "transit_gateway_default_route_table_id" {
  description = "Default TGW route table ID - used by modules/tgw-attachment to self-register each cluster's own pod CIDR as a static route for Cilium Cluster Mesh"
  value       = aws_ec2_transit_gateway.main.association_default_route_table_id
}

output "oidc_bucket_id" {
  description = "IRSA OIDC discovery bucket name - passed to modules/ec2's oidc_bucket_arn so the master role can publish its cluster's discovery docs"
  value       = module.oidc_bucket.bucket_id
}

output "oidc_bucket_arn" {
  value = module.oidc_bucket.bucket_arn
}

output "oidc_bucket_regional_domain_name" {
  description = "e.g. irsa-oidc-dev-phuoctd6.s3.ap-northeast-1.amazonaws.com - each cluster's issuer URL is https://<this>/<cluster_prefix>"
  value       = module.oidc_bucket.bucket_regional_domain_name
}
