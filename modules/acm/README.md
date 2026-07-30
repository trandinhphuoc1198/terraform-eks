# Module: `acm`

Provisions an **AWS Certificate Manager (ACM) SSL/TLS certificate** for HTTPS support on the Application Load Balancer. The certificate is automatically validated via DNS (Route 53 or manual CNAME records), and the module outputs the certificate ARN for use by the ALB's HTTPS listener.

---

## Resources created

| Resource | Name pattern | Purpose |
|---|---|---|
| `aws_acm_certificate` | `${env}-k8s-cert` | ACM certificate for the primary domain and `www.` subdomain (SAN) |
| `aws_route53_record` (×N, optional) | - | DNS CNAME validation records (only if `route53_zone_id` is set) |
| `aws_acm_certificate_validation` | - | Waits for the certificate to transition from PENDING_VALIDATION to ISSUED (only if `route53_zone_id` is set) |

---

## Validation methods

### Automatic (Route 53)

If `var.route53_zone_id` is provided, Terraform automatically:

1. Creates the required DNS validation CNAME records in the hosted zone.
2. Waits for ACM to validate the domain ownership (typically <1 minute).
3. Ensures the certificate is fully ISSUED before proceeding.

This is the recommended approach if your DNS is managed in Route 53.

### Manual (external DNS)

If `var.route53_zone_id` is left empty (`""`), the `validation_records` output provides the CNAME records you must manually add at your DNS provider. Once added, ACM will validate ownership automatically. You can then pass the certificate ARN to the root module's `alb` module.

> **Timing note:** If validating manually, you must add the DNS records before (or immediately after) `terraform apply`. If Terraform finishes before validation completes, the certificate remains in PENDING_VALIDATION and the ALB HTTPS listener will fail to attach it.

---

## Certificate details

| Attribute | Value |
|---|---|
| **Validation method** | DNS (CNAME) |
| **Domain names** | Primary domain + `www.` subdomain (SAN) |
| **Lifecycle** | `create_before_destroy` - during renewal/domain changes, the new cert is fully issued before the old one is deleted, preventing ALB downtime |
| **Auto-renewal** | Automatic (AWS ACM manages this) |

---

## Integration with ALB

Once the certificate is issued, pass its ARN to the root module's `alb` module:

```hcl
module "acm" {
  source         = "./modules/acm"
  env            = var.env
  domain_name    = "example.com"
  route53_zone_id = aws_route53_zone.main.id
}

module "alb" {
  source = "./modules/alb"
  # ... other variables ...
  certificate_arn = module.acm.certificate_arn  # ← Use the certificate ARN
  apps            = var.apps
}
```

The ALB's HTTPS listener (port 443) will use this certificate to terminate TLS connections. HTTP traffic (port 80) is automatically redirected to HTTPS.

---

## Variables

| Name | Type | Default | Description |
|---|---|---|---|
| `env` | `string` | - | Environment name - used as a tag on the certificate |
| `domain_name` | `string` | - | Primary domain for the certificate (e.g. `example.com`). A SAN for `www.<domain>` is added automatically. |
| `route53_zone_id` | `string` | `""` | Route 53 hosted zone ID for automatic DNS validation. Leave empty (`""`) if DNS is managed outside AWS - in that case, add CNAME records manually using the `validation_records` output. |

---

## Outputs

| Name | Description |
|---|---|
| `certificate_arn` | ARN of the issued ACM certificate - pass this to the `alb` module's `certificate_arn` variable |
| `validation_records` | Map of DNS validation CNAME records needed for ACM validation. Only required if `route53_zone_id` is empty (manual DNS validation). |

---

## Example usage

### With Route 53 (automatic validation)

```hcl
module "acm" {
  source         = "./modules/acm"
  env            = "dev"
  domain_name    = "app.example.com"
  route53_zone_id = "Z1234567890ABC"  # Your Route 53 hosted zone ID
}

output "certificate_arn" {
  value = module.acm.certificate_arn
}
```

### Without Route 53 (manual validation)

```hcl
module "acm" {
  source         = "./modules/acm"
  env            = "dev"
  domain_name    = "app.example.com"
  route53_zone_id = ""  # Leave empty for manual validation
}

output "validation_cnames" {
  value       = module.acm.validation_records
  description = "Add these CNAME records to your DNS provider"
}

# After manually adding the CNAME records to your DNS provider,
# run: terraform apply -var="certificate_arn=$(terraform output -raw certificate_arn)"
```

---

## Security notes

- ACM certificates are free and automatically renewed 30–60 days before expiration.
- The certificate is region-specific. If your ALB is in a different region than the certificate, use an ACM certificate in the ALB's region.
- The certificate covers the primary domain and `www.` subdomain by default. To add additional subdomains (SANs), modify the `subject_alternative_names` list in [main.tf](./main.tf).
