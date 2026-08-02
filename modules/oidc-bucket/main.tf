# One shared bucket, one prefix per cluster (hub-dev, spoke-dev, ...).
# Public-read is intentional and safe: the only objects ever stored here
# are the two static IRSA/OIDC discovery documents AWS STS needs to
# validate ServiceAccount tokens - the OIDC discovery doc and the JWKS
# (public signing keys only, never private key material). Nothing else
# should ever be uploaded to this bucket.
resource "aws_s3_bucket" "oidc" {
  bucket        = var.bucket_name
  force_destroy = true

  tags = {
    Name    = var.bucket_name
    Purpose = "irsa-oidc-discovery"
  }
}

resource "aws_s3_bucket_public_access_block" "oidc" {
  bucket = aws_s3_bucket.oidc.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "oidc" {
  bucket = aws_s3_bucket.oidc.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadOIDCDiscoveryDocsOnly"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.oidc.arn}/*"
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.oidc]
}
