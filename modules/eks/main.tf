# ── EKS Cluster IAM Role ─────────────────────────────────────────────────────
resource "aws_iam_role" "cluster" {
  name = "${var.env}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${var.env}-eks-cluster-role", Env = var.env }
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ── Additional control-plane security group ─────────────────────────────────
# EKS auto-creates its own cluster security group (exposed below as
# cluster_security_group_id) covering node<->control-plane traffic. This one
# is ours to control, for the same reason modules/ec2's master SG carried a
# trusted_api_cidr_blocks rule: letting the hub's ArgoCD reach a spoke's
# apiserver across the TGW, and vice versa if ever needed.
resource "aws_security_group" "cluster_additional" {
  name        = "${var.env}-eks-cluster-additional-sg"
  description = "Additional SG for the EKS control plane - trusted CIDR access to the API server"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = length(var.trusted_api_cidr_blocks) > 0 ? [1] : []
    content {
      description = "kube-apiserver (443) from trusted peer CIDRs, e.g. the other cluster's VPC over TGW"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = var.trusted_api_cidr_blocks
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.env}-eks-cluster-additional-sg" }
}

# ── EKS Cluster ──────────────────────────────────────────────────────────────
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.cluster_version

  vpc_config {
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    endpoint_private_access = var.endpoint_private_access
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.public_access_cidrs
    security_group_ids      = [aws_security_group.cluster_additional.id]
  }

  # Skip AWS's default self-managed addons (vpc-cni, kube-proxy, coredns) at
  # creation time. Cilium fully replaces vpc-cni AND kube-proxy
  # (kubeProxyReplacement: true - same setting already in
  # platform/values/base/cilium.yaml). CoreDNS is re-added explicitly below
  # as a standalone addon, since there's no reason for it to be anything
  # other than AWS-managed once Cilium's CNI is actually up.
  bootstrap_self_managed_addons = false

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  tags = {
    Name                                        = var.cluster_name
    Env                                         = var.env
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}

# ── CoreDNS addon ────────────────────────────────────────────────────────────
# Tolerates being scheduled before Cilium's CNI is up (EKS retries pod
# placement once networking is available) - safe to create alongside the
# cluster rather than gating it behind Cilium via ArgoCD.
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_cluster.this]
}

# NOTE - deliberately NOT installing the vpc-cni, kube-proxy, or aws-ebs-csi-driver
# EKS-managed addons here:
#   - vpc-cni / kube-proxy: replaced entirely by Cilium (ArgoCD-managed,
#     wave 10, same as the kubeadm setup).
#   - aws-ebs-csi-driver: already an ArgoCD Application in this repo
#     (argocd/{hub,spokes/infra}/50-aws-ebs-csi-driver.yaml) with its own
#     IRSA role - keep that as the single source of truth rather than
#     splitting ownership between Terraform and GitOps.
#
# Access entries (replacing the aws-auth ConfigMap model) live at the root -
# see live/hub/main.tf and live/spoke/main.tf.
