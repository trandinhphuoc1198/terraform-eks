# One aws_iam_openid_connect_provider per cluster (hub and spoke each have
# their own kubeadm-generated SA signing key -> their own issuer -> their
# own provider; tokens from one cluster must never validate against
# another's provider). Roles created here are scoped via the trust
# policy's "sub" condition to exactly one namespace:serviceaccount pair -
# that's the actual privilege boundary IRSA buys you over the node-role
# model everywhere else in this repo.

data "tls_certificate" "oidc" {
  url = var.oidc_issuer_url
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = var.oidc_issuer_url
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]

  tags = { Name = "${var.cluster_prefix}-irsa-oidc", Cluster = var.cluster_prefix }
}

locals {
  # Strip the scheme - IAM condition keys are written as
  # "<host/path>:sub", not "https://<host/path>:sub".
  oidc_provider_host = replace(var.oidc_issuer_url, "https://", "")
}

resource "aws_iam_role" "this" {
  for_each = var.roles

  name = "${var.cluster_prefix}-irsa-${each.key}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.this.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider_host}:aud" = "sts.amazonaws.com"
          "${local.oidc_provider_host}:sub" = "system:serviceaccount:${each.value.namespace}:${each.value.service_account}"
        }
      }
    }]
  })

  tags = {
    Name    = "${var.cluster_prefix}-irsa-${each.key}"
    Cluster = var.cluster_prefix
  }
}

resource "aws_iam_role_policy" "this" {
  for_each = var.roles

  name   = "${var.cluster_prefix}-irsa-${each.key}-policy"
  role   = aws_iam_role.this[each.key].id
  policy = each.value.policy_json
}
