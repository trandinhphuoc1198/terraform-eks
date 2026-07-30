output "bucket_ids" {
  value = {
    for k, v in aws_s3_bucket.this : k => v.id
  }
}

output "bucket_arns" {
  value = [for b in aws_s3_bucket.this : b.arn]
}
