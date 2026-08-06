output "master_userdata" {
  value = templatefile("${path.module}/templates/master_init.sh.tpl", {
    k8s_version              = var.k8s_version
    env                      = var.env
    vpc_cidr_supernet        = var.vpc_cidr_supernet
    install_cni_ccm          = var.install_cni_ccm
    oidc_issuer_url          = var.oidc_issuer_url
    oidc_s3_bucket           = var.oidc_s3_bucket
    oidc_s3_prefix           = var.oidc_s3_prefix
    cilium_operator_role_arn = var.cilium_operator_role_arn
    aws_ccm_role_arn         = var.aws_ccm_role_arn
  })
}

output "worker_userdata" {
  value = templatefile("${path.module}/templates/worker_init.sh.tpl", {
    env = var.env
  })
}
