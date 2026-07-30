variable "k8s_version" {
  type        = string
  description = "Kubernetes minor version (e.g. 1.29)"
}

variable "pod_cidr" {
  type        = string
  description = "Pod network CIDR passed to kubeadm --pod-network-cidr"
}

variable "env" {
  type        = string
  description = "The target deployment environment/cluster name (e.g. hub-dev, spoke-dev)"
}

variable "pod_cidr_supernet" {
  description = "Fleet-wide pod-CIDR supernet (see README). Sets Cilium's ipv4NativeRoutingCIDR so cross-cluster Cluster Mesh pod traffic isn't masqueraded - must stay wider than just this cluster's own pod_cidr."
  type        = string
  default     = "100.64.0.0/10"
}

variable "install_cni_ccm" {
  description = "If true, the master bootstrap script installs Cilium CNI and AWS CCM directly and waits for the node to become Ready. Set true for the hub (Argo CD itself needs a working pod network + cleared taint before it can run, so the hub can't outsource its own CNI/CCM to Argo CD). Set false for spokes - Argo CD's own ApplicationSet on the hub installs CNI/CCM into the spoke once it registers (see k8s-register-with-hub.yml), instead of this script doing it imperatively."
  type        = bool
  default     = true
}