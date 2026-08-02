# Module: `oidc-bucket`

Provisions the **one shared, public-read S3 bucket** that hosts every
cluster's IRSA OIDC discovery document and JWKS (public signing keys).
Applied once from `global/network` (see that root's `main.tf`) - both
`live/hub` and `live/spoke` read its outputs via the existing
`terraform_remote_state.network` data source, the same pattern already
used for `transit_gateway_id`.

## Why this exists

Masters have no public IP (see root README's "Access model"), but AWS STS
must be able to fetch each cluster's OIDC discovery doc + JWKS over HTTPS
to validate ServiceAccount tokens for IRSA-style `AssumeRoleWithWebIdentity`
calls. This bucket is the public mirror each master pushes its own
(otherwise-unreachable) discovery documents to at bootstrap time - see
the "IRSA: publish OIDC discovery + JWKS" step in
`modules/k8s/templates/master_init.sh.tpl`.

## What's public vs. private

Only `s3:GetObject` is public, and only the two static JSON documents each
cluster's master uploads (`<prefix>/.well-known/openid-configuration`,
`<prefix>/openid/v1/jwks`) should ever live in this bucket. Neither
contains anything sensitive - the JWKS is public key material only, never
the SA signing *private* key.

## Resources created

| Resource | Purpose |
|---|---|
| `aws_s3_bucket` | The shared bucket |
| `aws_s3_bucket_public_access_block` | Allows the bucket policy below to actually grant public read (bucket-level ACLs stay blocked) |
| `aws_s3_bucket_policy` | `s3:GetObject` for `Principal: "*"` on every object - required so AWS STS (an external, unauthenticated caller from AWS's perspective) can fetch it |

## Variables

| Name | Type | Description |
|---|---|---|
| `bucket_name` | `string` | Globally-unique bucket name |

## Outputs

| Name | Description |
|---|---|
| `bucket_id` | Bucket name |
| `bucket_arn` | Bucket ARN |
| `bucket_regional_domain_name` | e.g. `irsa-oidc-dev-phuoctd6.s3.ap-northeast-1.amazonaws.com` - each cluster's issuer URL is `https://<this>/<cluster_prefix>` |
