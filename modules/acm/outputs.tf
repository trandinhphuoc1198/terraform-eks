output "certificate_arn" {
  description = "ARN of the issued ACM certificate - passed to the ALB HTTPS listener"
  value       = aws_acm_certificate.this.arn
}

output "validation_records" {
  description = <<-EOT
    DNS CNAME records that must exist for ACM to validate domain ownership.
    If route53_zone_id is set, these are created automatically.
    If not, add them manually at your DNS provider before running terraform apply.
  EOT
  value = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }
}
