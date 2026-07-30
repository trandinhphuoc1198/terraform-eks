variable "env" { type = string }
variable "vpc_id" { type = string }
variable "vpc_cidr" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "master_instance_type" { type = string }
variable "key_name" { type = string }
variable "cluster_name" { type = string }
variable "master_private_ip" {
  type    = string
  default = null
}

variable "ami_id" {
  description = "AMI ID for the master node - the shared Packer-built k8s base image (see /packer and modules/ami). Replaces the previous dynamic SSM AL2023 lookup."
  type        = string
}

# NOTE: k8s_bootstrap was removed. The master no longer self-bootstraps via
# user_data - kubeadm init/CNI now runs via the k8s-cluster-bootstrap.yml
# CI workflow (SSM send-command), using module.k8s.master_userdata as the
# script content. This makes a failed bootstrap fail a CI job with logs,
# instead of failing silently inside cloud-init on a box nobody's watching.

variable "trusted_api_cidr_blocks" {
  description = <<-EOT
    CIDR blocks allowed to reach the kube-apiserver (port 6443) in addition
    to in-VPC traffic. Used to let the hub cluster's Argo CD reach this
    cluster's API server across the Transit Gateway. Leave empty on the hub
    itself (nothing needs to call *into* the hub's apiserver from a spoke).
  EOT
  type        = list(string)
  default     = []
}

variable "s3_bucket_arns" {
  description = "ARNs of S3 buckets the worker IAM role should be able to read/write. Leave empty (default) if this cluster has no S3-backed workloads - e.g. the hub."
  type        = list(string)
  default     = []
}

variable "register_with_hub" {
  description = "If true, grants this cluster's master role permission to push its own Argo CD registration credentials to Secrets Manager (argocd-clusters/<cluster_name>). Set true on spokes, false on the hub."
  type        = bool
  default     = false
}

variable "install_eso" {
  description = "If true, provisions the IAM identity External Secrets Operator uses to read every spoke's registration secret, plus SSM access for the CI registration workflow. Set true only on the hub."
  type        = bool
  default     = false
}

variable "master_volume_size" {
  description = "EBS volume size (in GB) for the master node root block device"
  type        = number
  default     = 20
}

variable "pod_cidr_supernet" {
  description = "Fleet-wide pod-CIDR supernet (default 100.64.0.0/10 - see README). Allowed as an ingress source on master/worker SGs so Cilium Cluster Mesh native-routed pod traffic from any other cluster isn't dropped at the node ENI."
  type        = string
  default     = "100.64.0.0/10"
}

variable "vpc_cidr_supernet" {
  description = "Fleet-wide VPC-CIDR supernet (default 10.0.0.0/8). Allowed as an ingress source on the worker SG for the clustermesh-apiserver NodePort, since cilium-agent connects using its node's real VPC IP (hostNetwork), not a pod IP."
  type        = string
  default     = "10.0.0.0/8"
}

variable "clustermesh_nodeport" {
  description = "NodePort the clustermesh-apiserver Service listens on - exposed to every other cluster in the fleet for Cilium Cluster Mesh"
  type        = number
  default     = 32379
}

variable "install_clustermesh_ca_push" {
  description = "If true, grants master + worker node roles secretsmanager write access (CreateSecret/PutSecretValue/DescribeSecret/TagResource) scoped to clustermesh/* - needed for platform/clustermesh/hub/ca-pushsecret.yaml to push the CA to Secrets Manager via ESO PushSecret. Hub only; every spoke's ExternalSecret only needs read, already covered elsewhere."
  type        = bool
  default     = false
}

variable "install_clustermesh_ca_pull" {
  description = "If true, grants master + worker node roles secretsmanager:GetSecretValue and DescribeSecret, scoped to clustermesh/*. Needed for platform/clustermesh/spoke/external-secret.yaml to pull the CA hub/ca-pushsecret.yaml pushed to Secrets Manager. Spoke only - read-only, mirrors hub's install_clustermesh_ca_push but without any write actions."
  type        = bool
  default     = false
}