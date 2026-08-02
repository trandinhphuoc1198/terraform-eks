output "bucket_id" {
  value = aws_s3_bucket.oidc.id
}

output "bucket_arn" {
  value = aws_s3_bucket.oidc.arn
}

output "bucket_regional_domain_name" {
  description = "e.g. irsa-oidc-dev-phuoctd6.s3.ap-northeast-1.amazonaws.com - used to build each cluster's https:// issuer URL (issuer = this + /<cluster_prefix>)"
  value       = aws_s3_bucket.oidc.bucket_regional_domain_name
}
