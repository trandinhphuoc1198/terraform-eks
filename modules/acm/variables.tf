variable "env" {
  description = "Environment name - used as a tag on the certificate"
  type        = string
}

variable "domain_name" {
  description = "Primary domain for the ACM certificate (e.g. example.com). A SAN for www.<domain> is added automatically."
  type        = string
}

variable "route53_zone_id" {
  description = <<-EOT
    Route 53 hosted zone ID for the domain.
    When set, Terraform automatically creates the DNS validation CNAME records
    and waits for the certificate to be fully issued before continuing.
    Leave as empty string ("") if your DNS is managed outside AWS - in that
    case add the CNAME records manually using the `acm_validation_records` output.
  EOT
  type        = string
  default     = ""
}
