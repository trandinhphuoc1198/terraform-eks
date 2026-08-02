variable "bucket_name" {
  description = "Globally-unique S3 bucket name to host every cluster's IRSA OIDC discovery doc + JWKS, one prefix per cluster"
  type        = string
}
