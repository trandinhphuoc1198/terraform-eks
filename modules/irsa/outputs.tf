output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.this.arn
}

output "role_arns" {
  description = "Map of role_key => IAM role ARN - annotate the matching ServiceAccount with eks.amazonaws.com/role-arn = this value"
  value       = { for k, r in aws_iam_role.this : k => r.arn }
}
