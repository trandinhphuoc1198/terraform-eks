# ── Managed Node Group ───────────────────────────────────────────────────────
# node_role_arn is created by the caller via modules/eks-node-role, with an
# aws_eks_access_entry for it created BEFORE this resource (module-level
# depends_on at the call site) - required so nodes can actually authenticate
# to the cluster under EKS's API auth mode. See that module's header comment.
resource "aws_eks_node_group" "this" {
  cluster_name    = var.cluster_name
  node_group_name = "${var.env}-${var.node_group_name}"
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.subnet_ids

  ami_type       = var.ami_type
  capacity_type  = var.capacity_type
  instance_types = var.instance_types

  disk_size = var.disk_size

  scaling_config {
    desired_size = var.desired_size
    min_size     = var.min_size
    max_size     = var.max_size
  }

  update_config {
    max_unavailable = 1
  }

  labels = var.labels

  dynamic "taint" {
    for_each = var.taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  # Desired size is managed here at first apply only, same lifecycle
  # ignore_changes pattern modules/asg used for Cluster Autoscaler - nothing
  # scales this pool automatically today (Karpenter handles the elastic
  # workload pool instead), but if you later put Cluster Autoscaler or
  # Karpenter's own EKS Auto Mode on this pool too, ignore it here.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}
