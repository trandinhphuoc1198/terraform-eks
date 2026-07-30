output "master_userdata" {
  value = templatefile("${path.module}/templates/master_init.sh.tpl", {
    k8s_version       = var.k8s_version
    pod_cidr          = var.pod_cidr
    pod_cidr_supernet = var.pod_cidr_supernet
    env               = var.env
    install_cni_ccm   = var.install_cni_ccm
  })
}

output "worker_userdata" {
  value = templatefile("${path.module}/templates/worker_init.sh.tpl", {
    env = var.env
  })
}