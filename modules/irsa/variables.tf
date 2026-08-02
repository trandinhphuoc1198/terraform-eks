variable "cluster_prefix" {
  description = "Cluster name, e.g. \"hub-dev\" or \"spoke-dev\" - prefixes every IAM role this module creates and is used as the S3 prefix that must match modules/k8s's oidc_s3_prefix for this cluster"
  type        = string
}

variable "oidc_issuer_url" {
  description = "Full https:// URL of this cluster's OIDC issuer (the S3 bucket regional domain + /<cluster_prefix>, no trailing slash) - must exactly match kube-apiserver's --service-account-issuer for this cluster"
  type        = string
}

variable "roles" {
  description = <<-EOT
    Map of role_key => { service_account, namespace, policy_json }. One IAM
    role is created per entry, trusted ONLY for that exact
    system:serviceaccount:<namespace>:<service_account> subject via
    AssumeRoleWithWebIdentity. Start with one entry (e.g. the EBS CSI
    controller) and grow this map as more workloads move off the shared
    node role.
  EOT
  type = map(object({
    service_account = string
    namespace       = string
    policy_json     = string
  }))
  default = {}
}
