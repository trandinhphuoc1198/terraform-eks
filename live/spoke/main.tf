# ── CIDR overlap guard ─────────────────────────────────────────────────────
locals {
  cidr_ranges = {
    for c in [var.vpc_cidr, var.hub_vpc_cidr] : c => {
      start = sum([for i, o in split(".", cidrhost(c, 0)) : tonumber(o) * pow(256, 3 - i)])
      end   = sum([for i, o in split(".", cidrhost(c, 0)) : tonumber(o) * pow(256, 3 - i)]) + pow(2, 32 - tonumber(split("/", c)[1])) - 1
    }
  }
}

check "no_cidr_overlap" {
  assert {
    condition = !(
      local.cidr_ranges[var.vpc_cidr].start <= local.cidr_ranges[var.hub_vpc_cidr].end &&
      local.cidr_ranges[var.hub_vpc_cidr].start <= local.cidr_ranges[var.vpc_cidr].end
    )
    error_message = "vpc_cidr (${var.vpc_cidr}) and hub_vpc_cidr (${var.hub_vpc_cidr}) overlap - they must be disjoint for TGW routing to work."
  }
}

data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ── VPC ───────────────────────────────────────────────────────────────────
# enable_karpenter_discovery stays true - Karpenter still provisions the
# workload node pool (fastapi-app, postgresql) exactly as before, it just
# joins nodes to EKS instead of running a kubeadm join script.
module "vpc" {
  source                     = "../../modules/vpc"
  env                        = var.env
  vpc_cidr                   = var.vpc_cidr
  public_subnet_cidrs        = var.public_subnet_cidrs
  private_subnet_cidrs       = var.private_subnet_cidrs
  region                     = var.region
  cluster_name               = var.cluster_name
  enable_karpenter_discovery = true
}

# ── Transit Gateway attachment - unchanged, still needed for Cluster Mesh ──
module "tgw_attachment" {
  source                = "../../modules/tgw-attachment"
  env                   = var.env
  transit_gateway_id    = data.terraform_remote_state.network.outputs.transit_gateway_id
  vpc_id                = module.vpc.vpc_id
  attachment_subnet_ids = module.vpc.private_subnet_ids
  route_table_ids       = [module.vpc.private_route_table_id, module.vpc.public_route_table_id]
  peer_cidr_blocks      = [var.hub_vpc_cidr]
}

# ── EKS control plane ───────────────────────────────────────────────────────
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
  trusted_api_cidr_blocks         = [var.hub_vpc_cidr] # lets the hub's ArgoCD reach this apiserver over TGW
  clustermesh_trusted_cidr_blocks = [var.hub_vpc_cidr]
  enable_karpenter_discovery      = true
}

# ── Platform node role, access entry, then the node group - IN THAT ORDER ──
# See live/hub/main.tf's comment on this same pattern for why the ordering
# matters: EKS's API auth mode requires the access entry to exist before an
# instance using that role tries to join, and role-output-as-input alone
# does not guarantee that ordering without an explicit depends_on.
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
# Runs cilium-operator, coredns, cert-manager, KEDA, CNPG operator, Karpenter
# itself, etc. Karpenter's controller runs HERE (on the stable MNG pool), not
# on the elastic pool it manages - same reasoning as the old "Karpenter on
# the master" placement (avoid the controller terminating its own node
# mid-drain), just moved from "the master" to "the platform MNG" since
# there's no master anymore.
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

# ── Karpenter node IAM role + access entry ──────────────────────────────────
# Karpenter's EC2NodeClass (platform/karpenter/spoke) references this role's
# NAME (not an instance profile ARN) directly - Karpenter creates and manages
# the instance profile itself on EKS. Nodes Karpenter launches don't join
# until well after this apply finishes (ArgoCD has to deploy Karpenter first,
# then something has to trigger a scale-out) so there's no in-apply race the
# way there is for the Managed Node Group above - but the access entry is
# still required for those nodes to ever successfully join at all, so it's
# created here rather than left as a manual follow-up step.
module "eks_node_role_karpenter" {
  source    = "../../modules/eks-node-role"
  env       = var.env
  role_name = "karpenter"
}

resource "aws_eks_access_entry" "karpenter_nodes" {
  cluster_name  = module.eks.cluster_name
  principal_arn = module.eks_node_role_karpenter.role_arn
  type          = "EC2_LINUX"
}

# ── IRSA: register this cluster's OIDC issuer + workload roles ─────────────
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
      policy_json     = local.eso_irsa_policy_spoke
    }
    aws-cloud-controller-manager = {
      service_account = "aws-cloud-controller-manager"
      namespace       = "kube-system"
      policy_json     = local.ccm_irsa_policy
    }
    cilium-operator = {
      service_account = "cilium-operator"
      namespace       = "kube-system"
      policy_json     = local.cilium_operator_irsa_policy
    }
    karpenter = {
      service_account = "karpenter"
      namespace       = "kube-system"
      policy_json     = local.karpenter_irsa_policy
    }
  }
}

# ── IAM policy documents ─────────────────────────────────────────────────────
locals {
  eso_irsa_policy_spoke = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "PullClustermeshCA"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:clustermesh/*"
    }]
  })

  ebs_csi_irsa_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EBSReadOnlyDescribe"
        Effect = "Allow"
        Action = [
          "ec2:DescribeVolumes", "ec2:DescribeVolumeStatus", "ec2:DescribeInstances",
          "ec2:DescribeSnapshots", "ec2:DescribeAvailabilityZones"
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
          StringEquals = { "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned" }
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

  # Simplified vs. the kubeadm version: no more iam:PassRole/GetInstanceProfile
  # against a Terraform-managed worker instance profile, since Karpenter on
  # EKS creates and owns its own instance profile from the role name given in
  # EC2NodeClass.spec.role. Still needs PassRole on the Karpenter node role
  # itself so it can launch instances under it.
  karpenter_irsa_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "KarpenterEC2ResourceDiscovery"
        Effect = "Allow"
        Action = [
          "ec2:DescribeAvailabilityZones", "ec2:DescribeCapacityReservations", "ec2:DescribeImages",
          "ec2:DescribeInstances", "ec2:DescribeInstanceStatus", "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstanceTypeOfferings", "ec2:DescribeLaunchTemplates",
          "ec2:DescribeLaunchTemplateVersions", "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory", "ec2:DescribeSubnets"
        ]
        Resource = "*"
      },
      {
        Sid      = "KarpenterEC2Provisioning"
        Effect   = "Allow"
        Action   = ["ec2:CreateFleet", "ec2:CreateLaunchTemplate", "ec2:RunInstances"]
        Resource = "*"
      },
      {
        Sid    = "KarpenterCreateTagsDuringProvisioning"
        Effect = "Allow"
        Action = ["ec2:CreateTags"]
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:fleet/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:launch-template/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:network-interface/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:spot-instances-request/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:volume/*"
        ]
        Condition = {
          StringEquals = { "ec2:CreateAction" = ["CreateFleet", "CreateLaunchTemplate", "RunInstances"] }
        }
      },
      {
        Sid      = "KarpenterTagOwnedInstances"
        Effect   = "Allow"
        Action   = ["ec2:CreateTags"]
        Resource = "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/*"
        Condition = {
          StringEquals = { "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned" }
          StringLike   = { "aws:ResourceTag/karpenter.sh/nodepool" = "*" }
        }
      },
      {
        Sid      = "KarpenterTerminateOwnedInstances"
        Effect   = "Allow"
        Action   = ["ec2:TerminateInstances"]
        Resource = "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/*"
        Condition = {
          StringEquals = { "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned" }
          StringLike   = { "aws:ResourceTag/karpenter.sh/nodepool" = "*" }
        }
      },
      {
        Sid      = "KarpenterDeleteOwnedLaunchTemplates"
        Effect   = "Allow"
        Action   = ["ec2:DeleteLaunchTemplate"]
        Resource = "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:launch-template/*"
        Condition = {
          StringEquals = { "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned" }
          StringLike   = { "aws:ResourceTag/karpenter.sh/nodepool" = "*" }
        }
      },
      {
        Sid      = "KarpenterPassNodeRole"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = module.eks_node_role_karpenter.role_arn
        Condition = {
          StringEquals = { "iam:PassedToService" = "ec2.amazonaws.com" }
        }
      },
      {
        Sid      = "KarpenterCreateAndUseInstanceProfile"
        Effect   = "Allow"
        Action   = ["iam:CreateInstanceProfile", "iam:TagInstanceProfile", "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile", "iam:DeleteInstanceProfile", "iam:GetInstanceProfile"]
        Resource = "*"
      },
      {
        Sid      = "KarpenterListInstanceProfiles"
        Effect   = "Allow"
        Action   = ["iam:ListInstanceProfiles"]
        Resource = "*"
      },
      {
        Sid      = "KarpenterReadSSMParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/aws/service/*"
      },
      {
        Sid      = "KarpenterReadPricing"
        Effect   = "Allow"
        Action   = ["pricing:GetProducts"]
        Resource = "*"
      },
      {
        Sid      = "KarpenterEKSDescribe"
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = module.eks.cluster_arn
      }
    ]
  })
}

# ── CI role for GitHub Actions to talk to the cluster directly ─────────────
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
        Sid    = "PushOwnRegistrationSecretOnly"
        Effect = "Allow"
        Action = [
          "secretsmanager:CreateSecret", "secretsmanager:PutSecretValue",
          "secretsmanager:TagResource", "secretsmanager:DescribeSecret"
        ]
        Resource = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:argocd-clusters/${var.cluster_name}-*"
      }
    ]
  })
}

# ── CI access entry ──────────────────────────────────────────────────────────
# Without this, argocd_registration_ci's IAM permissions (above) let it call
# eks:DescribeCluster to build a kubeconfig, but every kubectl/helm call
# against the live API would still be denied - IAM policy alone doesn't
# grant in-cluster RBAC under API auth mode, an access entry does. This is
# what replaces the old SSM-send-command path for the spoke registration
# flow (creating the argocd-manager ServiceAccount, pushing its token) - see
# MIGRATION_NOTES.md.
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

output "argocd_registration_ci_role_arn" {
  value = aws_iam_role.argocd_registration_ci.arn
}

output "karpenter_node_role_name" {
  description = "Pass this to platform/karpenter/spoke's EC2NodeClass.spec.role via the ApplicationSet's helm.parameters"
  value       = module.eks_node_role_karpenter.role_name
}
