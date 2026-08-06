variable "k8s_version" {
  type        = string
  description = "Kubernetes minor version (e.g. 1.29)"
}

variable "env" {
  type        = string
  description = "The target deployment environment/cluster name (e.g. hub-dev, spoke-dev)"
}

variable "vpc_cidr_supernet" {
  description = "Fleet-wide VPC-CIDR supernet - sets Cilium's ipv4NativeRoutingCIDR so cross-cluster Cluster Mesh pod traffic (now carrying real VPC IPs under ENI-mode IPAM) isn't masqueraded"
  type        = string
  default     = "10.0.0.0/8"
}

variable "install_cni_ccm" {
  description = "If true, the master bootstrap script installs Cilium CNI and AWS CCM directly and waits for the node to become Ready. Set true for the hub (Argo CD itself needs a working pod network + cleared taint before it can run, so the hub can't outsource its own CNI/CCM to Argo CD). Set false for spokes - Argo CD's own ApplicationSet on the hub installs CNI/CCM into the spoke once it registers (see k8s-register-with-hub.yml), instead of this script doing it imperatively."
  type        = bool
  default     = true
}

# ── IRSA / OIDC ────────────────────────────────────────────────────────────
# Leave all three at their default ("") to skip IRSA entirely - the
# bootstrap script no-ops the publish step and kube-apiserver starts with
# no --service-account-issuer override (unchanged behavior).
variable "oidc_issuer_url" {
  description = "This cluster's IRSA OIDC issuer URL, e.g. https://irsa-oidc-dev-phuoctd6.s3.ap-northeast-1.amazonaws.com/hub-dev - must exactly match modules/irsa's oidc_issuer_url for the same cluster. Passed to kube-apiserver's --service-account-issuer."
  type        = string
  default     = ""
}

variable "oidc_s3_bucket" {
  description = "Name of the shared IRSA OIDC bucket (modules/oidc-bucket's bucket_id) the master publishes its discovery doc + JWKS to at bootstrap"
  type        = string
  default     = ""
}

variable "oidc_s3_prefix" {
  description = "This cluster's prefix inside the shared OIDC bucket, e.g. \"hub-dev\" - must match the path component of oidc_issuer_url"
  type        = string
  default     = ""
}

variable "cilium_operator_role_arn" {
  description = "The ARN of the IAM role for the Cilium operator"
  type        = string
  default     = ""
}

variable "aws_ccm_role_arn" {
  description = "The ARN of the IAM role for the AWS CCM"
  type        = string
  default     = ""
}
