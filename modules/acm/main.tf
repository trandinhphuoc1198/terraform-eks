# ── ACM Certificate ───────────────────────────────────────────────────────────
# create_before_destroy ensures a new cert is fully issued before the old one
# is destroyed during any future domain change - preventing ALB downtime.
resource "aws_acm_certificate" "this" {
  domain_name               = var.domain_name
  subject_alternative_names = ["www.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.env}-k8s-cert"
    Env  = var.env
  }
}

# ── Route 53 DNS validation records (optional) ────────────────────────────────
# Only created when route53_zone_id is provided.
# If you manage DNS outside AWS, skip this block and add the CNAME records
# manually using the values from the `acm_validation_records` root output.
resource "aws_route53_record" "validation" {
  for_each = var.route53_zone_id != "" ? {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  zone_id         = var.route53_zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
  allow_overwrite = true
}

# ── Wait for certificate to be fully issued ───────────────────────────────────
# Only runs when Route 53 automation is enabled (route53_zone_id is set).
# Without this, terraform apply finishes immediately and the ALB HTTPS listener
# may reference a certificate that is still in PENDING_VALIDATION state.
resource "aws_acm_certificate_validation" "this" {
  count           = var.route53_zone_id != "" ? 1 : 0
  certificate_arn = aws_acm_certificate.this.arn

  validation_record_fqdns = [
    for record in aws_route53_record.validation : record.fqdn
  ]
}
