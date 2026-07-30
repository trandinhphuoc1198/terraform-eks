resource "aws_s3_bucket" "this" {
  for_each = toset(var.bucket_names)

  bucket = each.value

  force_destroy = true

  tags = {
    Name = each.value
    Env  = var.env
  }
}