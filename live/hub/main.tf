# ── CIDR overlap guard ─────────────────────────────────────────────────────
locals {
  all_cidrs = concat([var.vpc_cidr], var.spoke_vpc_cidrs)

  cidr_ranges = {
    for c in local.all_cidrs : c => {
      start = sum([for i, o in split(".", cidrhost(c, 0)) : tonumber(o) * pow(256, 3 - i)])
      end   = sum([for i, o in split(".", cidrhost(c, 0)) : tonumber(o) * pow(256, 3 - i)]) + pow(2, 32 - tonumber(split("/", c)[1])) - 1
    }
  }

  cidr_pairs = [
    for pair in setproduct(range(length(local.all_cidrs)), range(length(local.all_cidrs))) :
    [local.all_cidrs[pair[0]], local.all_cidrs[pair[1]]] if pair[0] < pair[1]
  ]

  overlapping_pairs = [
    for pair in local.cidr_pairs :
    pair if local.cidr_ranges[pair[0]].start <= local.cidr_ranges[pair[1]].end
    && local.cidr_ranges[pair[1]].start <= local.cidr_ranges[pair[0]].end
  ]
}

check "no_cidr_overlap" {
  assert {
    condition     = length(local.overlapping_pairs) == 0
    error_message = "Overlapping CIDRs detected: ${jsonencode(local.overlapping_pairs)}. vpc_cidr and every entry in spoke_vpc_cidrs must be disjoint for TGW routing to work."
  }
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

# ── VPC ───────────────────────────────────────────────────────────────────
# EKS still needs the same private/public subnet split,
# NAT gateway, S3 endpoint, and SSM interface endpoints (SSM access to nodes
# is still useful for debugging even though there's no more master to reach
# this way). enable_karpenter_discovery stays false on hub, same as before -
# hub runs no Karpenter workload pool, only the platform Managed Node Group.
module "vpc" {
  source                     = "../../modules/vpc"
  env                        = var.env
  vpc_cidr                   = var.vpc_cidr
  public_subnet_cidrs        = var.public_subnet_cidrs
  private_subnet_cidrs       = var.private_subnet_cidrs
  region                     = var.region
  cluster_name               = var.cluster_name
  enable_karpenter_discovery = false
}

# ── Transit Gateway attachment - needed for Cluster Mesh ──
module "tgw_attachment" {
  source                = "../../modules/tgw-attachment"
  env                   = var.env
  transit_gateway_id    = data.terraform_remote_state.network.outputs.transit_gateway_id
  vpc_id                = module.vpc.vpc_id
  attachment_subnet_ids = module.vpc.private_subnet_ids
  route_table_ids       = [module.vpc.private_route_table_id, module.vpc.public_route_table_id]
  peer_cidr_blocks      = var.spoke_vpc_cidrs
}

# ── EKS control plane ───────────────────────────────────────────────────────
# Replaces modules/ec2's master instance + modules/k8s's master_userdata
# (kubeadm init/CNI bootstrap script) entirely - no master EC2 instance, no
# SSM send-command bootstrap job. public_access_cidrs left wide open here
# deliberately (see modules/eks/variables.tf's warning) so GitHub-hosted
# Actions runners can reach the API server directly; tighten once you've
# decided between IAM-only trust vs a self-hosted runner inside the VPC.
module "eks" {
  source                          = "../../modules/eks"
  env                             = var.env
  cluster_name                    = var.cluster_name
  cluster_version                 = var.eks_cluster_version
  vpc_id                          = module.vpc.vpc_id
  private_subnet_ids              = module.vpc.private_subnet_ids
  public_subnet_ids               = module.vpc.public_subnet_ids
  endpoint_private_access         = true
  endpoint_public_access          = true
  trusted_api_cidr_blocks         = var.spoke_vpc_cidrs
  clustermesh_trusted_cidr_blocks = var.spoke_vpc_cidrs
  enable_karpenter_discovery      = false
}

# ── Node role, access entry, then the node group - IN THAT ORDER ───────────
# EKS's API auth mode authorizes nodes by IAM role via an access entry. That
# entry must exist BEFORE an EC2 instance using the role tries to join, or
# it comes up stuck NotReady with no obvious error surfaced anywhere. The
# role is created first (its own module, no dependency on the node group),
# the access entry next (depends on both the cluster and the role), and only
# then the node group itself (explicit depends_on the access entry - just
# referencing the role's ARN as an input is NOT enough to guarantee ordering,
# since the access entry and the node group would otherwise have no edge
# between them and could apply in parallel).
module "eks_node_role_platform" {
  source    = "../../modules/eks-node-role"
  env       = var.env
  role_name = "platform"
}

resource "aws_eks_access_entry" "platform_nodes" {
  cluster_name  = module.eks.cluster_name
  principal_arn = module.eks_node_role_platform.role_arn
  type          = "EC2_LINUX"
}

# ── Managed Node Group: baseline platform pool ──────────────────────────────
# Runs ArgoCD, cilium-operator, coredns, cert-manager, external-secrets, etc.
# Untainted - this is where everything lands by default. Workload pods
# (fastapi-app, postgresql) don't run on hub at all; hub is control-plane-only
# for the fleet, same division of responsibility as before.
module "eks_node_group_platform" {
  source                    = "../../modules/eks-node-group"
  env                       = var.env
  cluster_name              = module.eks.cluster_name
  node_group_name           = "platform"
  node_role_arn             = module.eks_node_role_platform.role_arn
  subnet_ids                = module.vpc.private_subnet_ids
  instance_types            = [var.master_instance_type, var.worker_instance_type]
  desired_size              = var.worker_desired
  min_size                  = var.worker_min
  max_size                  = var.worker_max
  disk_size                 = var.worker_volume_size
  cluster_security_group_id = module.eks.cluster_security_group_id
  additional_security_group_ids = [
    module.eks.clustermesh_security_group_id,
    module.eks.node_shared_security_group_id # the only one CCM should touch
  ]
  depends_on = [aws_eks_access_entry.platform_nodes]
}

# ── CI access entry ──────────────────────────────────────────────────────────
# No node-join race here (this grants a human/CI IAM role kubectl/helm
# access, not something an EC2 instance needs at boot), so no depends_on
# ordering is required - but declared after aws_iam_role.argocd_registration_ci
# further down this file, which Terraform resolves regardless of file order.
resource "aws_eks_access_entry" "ci" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.argocd_registration_ci.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "ci_admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.argocd_registration_ci.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.ci]
}

# ── IRSA: register this cluster's OIDC issuer + workload roles ─────────────
# Same module as before, but oidc_issuer_url now comes straight from EKS
# itself (module.eks.cluster_oidc_issuer_url) instead of the hand-rolled
# modules/oidc-bucket + master's self-publish step - that whole mechanism
# (aws_s3_bucket public-read discovery docs, the "publish OIDC discovery"
# step in master_init.sh.tpl) is deleted; EKS hosts its own OIDC endpoint.
#
# Roles that used to need DIRECT env-var injection (cilium-operator,
# aws-cloud-controller-manager) because pod-identity-webhook and ArgoCD
# didn't exist yet at day-0 no longer need that special-casing - EKS's
# control plane runs its own IRSA mutating webhook unconditionally, so every
# role below just becomes a normal ServiceAccount annotation from wave 0.
module "irsa" {
  source          = "../../modules/irsa"
  cluster_prefix  = var.env
  oidc_issuer_url = module.eks.cluster_oidc_issuer_url

  roles = {
    ebs-csi-controller = {
      service_account = "ebs-csi-controller-sa"
      namespace       = "kube-system"
      policy_json     = local.ebs_csi_irsa_policy
    }
    external-secrets = {
      service_account = "external-secrets"
      namespace       = "external-secrets"
      policy_json     = local.eso_irsa_policy_hub
    }
    loki = {
      service_account = "loki"
      namespace       = "observability"
      policy_json     = local.loki_irsa_policy
    }
    tempo = {
      service_account = "tempo"
      namespace       = "observability"
      policy_json     = local.tempo_irsa_policy
    }
    cloud-controller-manager = {
      service_account = "cloud-controller-manager"
      namespace       = "kube-system"
      policy_json     = local.ccm_irsa_policy
    }
    cilium-operator = {
      service_account = "cilium-operator"
      namespace       = "kube-system"
      policy_json     = local.cilium_operator_irsa_policy
    }
  }
}

# ── IAM policy documents (unchanged from the kubeadm version) ──────────────
locals {
  eso_irsa_policy_hub = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadArgocdClusterRegistrationSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecrets"
        ]
        Resource = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:argocd-clusters/*"
      },
      {
        Sid    = "PushClustermeshCA"
        Effect = "Allow"
        Action = [
          "secretsmanager:CreateSecret",
          "secretsmanager:PutSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:TagResource",
          "secretsmanager:GetSecretValue"
        ]
        Resource = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:clustermesh/*"
      }
    ]
  })

  ebs_csi_irsa_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EBSReadOnlyDescribe"
        Effect = "Allow"
        Action = [
          "ec2:DescribeVolumes", "ec2:DescribeVolumeStatus",
          "ec2:DescribeInstances", "ec2:DescribeSnapshots",
          "ec2:DescribeAvailabilityZones"
        ]
        Resource = "*"
      },
      {
        Sid      = "EBSCreateTaggedForThisCluster"
        Effect   = "Allow"
        Action   = ["ec2:CreateVolume", "ec2:CreateSnapshot"]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestTag/ebs.csi.aws.com/cluster" = "true" }
        }
      },
      {
        Sid      = "EBSAttachDetachOnThisClustersInstances"
        Effect   = "Allow"
        Action   = ["ec2:AttachVolume", "ec2:DetachVolume"]
        Resource = "arn:aws:ec2:*:*:instance/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
        }
      },
      {
        Sid      = "EBSAttachDetachOnTaggedVolumes"
        Effect   = "Allow"
        Action   = ["ec2:AttachVolume", "ec2:DetachVolume"]
        Resource = "arn:aws:ec2:*:*:volume/*"
        Condition = {
          StringEquals = { "aws:ResourceTag/ebs.csi.aws.com/cluster" = "true" }
        }
      },
      {
        Sid      = "EBSMutateVolumeOnlyResourcesTaggedForThisCluster"
        Effect   = "Allow"
        Action   = ["ec2:DeleteVolume", "ec2:DeleteSnapshot", "ec2:ModifyVolume"]
        Resource = "arn:aws:ec2:*:*:volume/*"
        Condition = {
          StringEquals = { "aws:ResourceTag/ebs.csi.aws.com/cluster" = "true" }
        }
      },
      {
        Sid      = "EBSCreateTagsOnNewVolumesAndSnapshots"
        Effect   = "Allow"
        Action   = ["ec2:CreateTags"]
        Resource = "*"
        Condition = {
          StringEquals = { "ec2:CreateAction" = ["CreateVolume", "CreateSnapshot"] }
        }
      }
    ]
  })

  loki_irsa_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "LokiOwnBucketOnly"
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
      Resource = ["arn:aws:s3:::${module.s3.bucket_ids["loki-s3-phuoctd6"]}", "arn:aws:s3:::${module.s3.bucket_ids["loki-s3-phuoctd6"]}/*"]
    }]
  })

  tempo_irsa_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "TempoOwnBucketOnly"
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
      Resource = ["arn:aws:s3:::${module.s3.bucket_ids["tempo-s3-phuoctd6"]}", "arn:aws:s3:::${module.s3.bucket_ids["tempo-s3-phuoctd6"]}/*"]
    }]
  })

  # aws-cloud-controller-manager kept self-managed (not the EKS-implicit
  # provider) so LoadBalancer-type Services created by Cilium's Gateway API
  # continue to get real NLBs the exact same way they did pre-migration -
  # EKS does not run this for you automatically.
  ccm_irsa_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadOnlyDescribe"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances", "ec2:DescribeRegions", "ec2:DescribeRouteTables",
          "ec2:DescribeSecurityGroups", "ec2:DescribeSubnets", "ec2:DescribeVolumes",
          "ec2:DescribeAvailabilityZones", "ec2:DescribeInstanceTopology"
        ]
        Resource = "*"
      },
      {
        Sid      = "CreateSecurityGroupTaggedForThisCluster"
        Effect   = "Allow"
        Action   = "ec2:CreateSecurityGroup"
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}" = "owned" }
        }
      },
      {
        Sid    = "MutateOnlyResourcesTaggedForThisCluster"
        Effect = "Allow"
        Action = [
          "ec2:CreateTags", "ec2:DeleteSecurityGroup", "ec2:ModifyInstanceAttribute",
          "ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress"
        ]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned" }
        }
      },
      {
        Sid    = "ELBManageForCCMProvisionedLoadBalancers"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateLoadBalancer", "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:DescribeLoadBalancers", "elasticloadbalancing:DescribeLoadBalancerAttributes",
          "elasticloadbalancing:ModifyLoadBalancerAttributes", "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:DeleteListener", "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:ModifyListener", "elasticloadbalancing:CreateTargetGroup",
          "elasticloadbalancing:DeleteTargetGroup", "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetGroupAttributes", "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes", "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:DeregisterTargets", "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:RegisterInstancesWithLoadBalancer", "elasticloadbalancing:DeregisterInstancesFromLoadBalancer",
          "elasticloadbalancing:CreateLoadBalancerListeners", "elasticloadbalancing:DeleteLoadBalancerListeners",
          "elasticloadbalancing:ConfigureHealthCheck", "elasticloadbalancing:AttachLoadBalancerToSubnets",
          "elasticloadbalancing:DetachLoadBalancerFromSubnets", "elasticloadbalancing:ApplySecurityGroupsToLoadBalancer",
          "elasticloadbalancing:SetLoadBalancerPoliciesOfListener", "elasticloadbalancing:CreateLoadBalancerPolicy",
          "elasticloadbalancing:AddTags", "elasticloadbalancing:RemoveTags", "elasticloadbalancing:DescribeTags",
          "ec2:DescribeVpcs"
        ]
        Resource = "*"
      }
    ]
  })

  cilium_operator_irsa_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CiliumENIReadOnlyDescribe"
        Effect = "Allow"
        Action = [
          "ec2:DescribeSubnets", "ec2:DescribeVpcs", "ec2:DescribeVpcPeeringConnections",
          "ec2:DescribeSecurityGroups", "ec2:DescribeInstances", "ec2:DescribeInstanceTypes",
          "ec2:DescribeNetworkInterfaces", "ec2:DescribeRouteTables", "ec2:DescribeTags"
        ]
        Resource = "*"
      },
      {
        Sid    = "CiliumENILifecycle"
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface", "ec2:AttachNetworkInterface", "ec2:DetachNetworkInterface",
          "ec2:DeleteNetworkInterface", "ec2:ModifyNetworkInterfaceAttribute",
          "ec2:AssignPrivateIpAddresses", "ec2:UnassignPrivateIpAddresses",
          "ec2:AssignIpv6Addresses", "ec2:UnassignIpv6Addresses"
        ]
        Resource = "*"
      },
      {
        Sid      = "CiliumENICreateTagsOnNewInterfaces"
        Effect   = "Allow"
        Action   = ["ec2:CreateTags"]
        Resource = "arn:${data.aws_partition.current.partition}:ec2:*:*:network-interface/*"
        Condition = {
          StringEquals = { "ec2:CreateAction" = "CreateNetworkInterface" }
        }
      }
    ]
  })
}

# ── S3 Buckets (Loki/Tempo) - unchanged ─────────────────────────────────────
module "s3" {
  source       = "../../modules/s3"
  bucket_names = var.bucket_names
  env          = var.env
}

# ── CI role for GitHub Actions to talk to the cluster directly ─────────────
# Replaces the old argocd_registration_ci role's SSM-send-command permissions
# entirely - there's no master instance to SSM into anymore. This role is
# now granted an EKS access entry (see aws_eks_access_entry.ci above) with
# AmazonEKSAdminPolicy, so CI runs `aws eks update-kubeconfig` + kubectl/helm
# directly. Scope this down from Admin once you know exactly which
# operations CI needs (installing ArgoCD, checking registration secrets).
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_role" "argocd_registration_ci" {
  name = "${var.env}-argocd-registration-ci"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = "repo:trandinhphuoc1198*/*:*" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "argocd_registration_ci" {
  name = "${var.env}-argocd-registration-ci-policy"
  role = aws_iam_role.argocd_registration_ci.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DescribeClusterForKubeconfig"
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = module.eks.cluster_arn
      },
      {
        Sid      = "ListClustersForHubLookup"
        Effect   = "Allow"
        Action   = ["eks:ListClusters"]
        Resource = "*"
      },
      {
        Sid      = "ReadSpokeRegistrationSecrets"
        Effect   = "Allow"
        Action   = ["secretsmanager:DescribeSecret", "secretsmanager:GetSecretValue"]
        Resource = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:argocd-clusters/*"
      }
    ]
  })
}

output "argocd_registration_ci_role_arn" {
  value = aws_iam_role.argocd_registration_ci.arn
}
