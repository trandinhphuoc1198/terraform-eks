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
      description = "kube-apiserver 443 from trusted peer CIDRs  the other clusters VPC over TGW"
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

# ── Cluster Mesh security group ─────────────────────────────────────────────
# The EKS-auto-created cluster security group only covers intra-cluster
# node<->control-plane traffic. Cluster Mesh needs node<->node traffic
# from the PEER cluster's VPC (over the shared TGW) - WireGuard for the
# encrypted overlay and the clustermesh-apiserver NodePort. Attached to
# node ENIs via modules/eks-node-group's launch template, not to the
# control plane itself (mirrors the old modules/ec2 worker SG rule that
# opened these same two ports to vpc_cidr_supernet).
resource "aws_security_group" "clustermesh" {
  name        = "${var.env}-eks-clustermesh-sg"
  description = "Cilium Cluster Mesh - WireGuard + clustermesh-apiserver from peer cluster CIDR(s)"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = length(var.clustermesh_trusted_cidr_blocks) > 0 ? [1] : []
    content {
      description = "Cilium WireGuard overlay from peer cluster(s)"
      from_port   = 51871
      to_port     = 51871
      protocol    = "udp"
      cidr_blocks = var.clustermesh_trusted_cidr_blocks
    }
  }

  dynamic "ingress" {
    for_each = length(var.clustermesh_trusted_cidr_blocks) > 0 ? [1] : []
    content {
      description = "clustermesh-apiserver NodePort from peer cluster(s)"
      from_port   = var.clustermesh_nodeport
      to_port     = var.clustermesh_nodeport
      protocol    = "tcp"
      cidr_blocks = var.clustermesh_trusted_cidr_blocks
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    {
      Name = "${var.env}-eks-clustermesh-sg"
    },
    var.enable_karpenter_discovery ? { "karpenter.sh/discovery" = var.cluster_name } : {}
  )
}

resource "aws_security_group" "node_shared" {
  name        = "${var.env}-eks-node-shared-sg"
  description = "CCM-managed - NodePort ingress rules for LoadBalancer Services are added here at runtime, not by Terraform"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name                                        = "${var.env}-eks-node-shared-sg"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }

  # CCM adds/removes ingress rules directly via the AWS API as
  # LoadBalancer Services come and go - Terraform must not fight that,
  # same reasoning as the old modules/ec2 master/worker SGs.
  lifecycle {
    ignore_changes = [ingress, egress]
  }
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

# Tags EKS's own auto-created cluster security group so Karpenter's
# EC2NodeClass can discover it by tag (karpenter.sh/discovery), same
# convention as every other discovery tag in this repo (modules/vpc
# subnets, the clustermesh SG below). This SG is created implicitly by
# aws_eks_cluster - Terraform doesn't manage it as a first-class resource,
# so aws_ec2_tag is used to tag an existing resource by ID rather than
# owning its full lifecycle.
resource "aws_ec2_tag" "cluster_sg_karpenter_discovery" {
  count = var.enable_karpenter_discovery ? 1 : 0

  resource_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}