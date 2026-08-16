
# ── Launch template ──────────────────────────────────────────────────────
# Exists solely to attach extra security groups (Cluster Mesh, anything in
# additional_security_group_ids) - AMI selection still comes from
# var.ami_type on the node group below, NOT from image_id here, so EKS
# keeps managing AMI upgrades the normal way.
resource "aws_launch_template" "this" {
  name_prefix = "${var.env}-${var.node_group_name}-"

  network_interfaces {
    security_groups = concat(
      [var.cluster_security_group_id],
      var.additional_security_group_ids
    )
  }

  # IMDSv2 enforced (http_tokens = required), with a hop limit above AWS's
  # default of 1 - default 1 only reaches processes in the host's own
  # network namespace. cilium-operator's ENI IPAM calls (CreateNetworkInterface,
  # AttachNetworkInterface, etc. - see the cilium_operator_irsa_policy /
  # platform_node_cilium_eni role policy in live/hub|spoke/main.tf) need to
  # reach IMDS across one extra hop from the pod network namespace, which a
  # hop limit of 1 silently drops with no obvious error beyond IMDS calls
  # timing out. Tunable via var.metadata_http_put_response_hop_limit if a
  # given node group never needs more than the AWS default.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = var.metadata_http_put_response_hop_limit
    instance_metadata_tags      = "disabled"
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.env}-${var.node_group_name}-node" }
  }

  lifecycle {
    create_before_destroy = true
  }
}

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

  launch_template {
    id      = aws_launch_template.this.id
    version = aws_launch_template.this.latest_version
  }

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
