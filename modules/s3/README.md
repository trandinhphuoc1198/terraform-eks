# Module: `s3`

Provisions one or more **S3 buckets** for application and cluster use. Bucket names are passed in as a list, so the number of buckets is fully configurable from the root module without changing this module's code.

---

## Resources created

| Resource | Name pattern | Purpose |
|---|---|---|
| `aws_s3_bucket` (×N) | `${name}-${env}` | One bucket per entry in `var.bucket_names`, suffixed with the environment name |

---

## Design notes

**Environment suffix**

Each bucket name is suffixed with `-${env}` (e.g. `my-data-dev`, `my-data-prod`). This ensures bucket names stay unique across environments when deployed in the same AWS account and makes it clear which environment a bucket belongs to.

**Force destroy**

All buckets are created with `force_destroy = true`. This allows `terraform destroy` to succeed even if the bucket contains objects. This is intentional for dev/prod parity in a kubeadm cluster context where storage is ephemeral - but consider setting this to `false` and enabling versioning for buckets holding critical data.

**For-each pattern**

The module uses `for_each` over a `toset` of bucket names, which means each bucket is tracked individually in Terraform state. Adding a new name to the list creates only that bucket; removing one destroys only that bucket - no accidental recreation of existing buckets.

---

## Variables

| Name | Type | Description |
|---|---|---|
| `bucket_names` | `list(string)` | Base names for the S3 buckets. Each is suffixed with `-${env}` at creation time. |
| `env` | `string` | Environment name - appended to every bucket name |

---

## Outputs

| Name | Description |
|---|---|
| `bucket_ids` | Map of `bucket_base_name → bucket_id` for all created buckets. Useful for referencing buckets in IAM policies or application config. |

---

## Example

```hcl
module "s3" {
  source       = "./modules/s3"
  env          = "dev"
  bucket_names = ["app-uploads", "cluster-logs"]
}

# Creates: app-uploads-dev, cluster-logs-dev

output "upload_bucket" {
  value = module.s3.bucket_ids["app-uploads"]
  # → "app-uploads-dev"
}
```
