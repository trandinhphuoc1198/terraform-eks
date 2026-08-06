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

# ── IRSA / OIDC ─────────────────────────────────────────────────────────────
# Mirrors live/hub/main.tf's block - see the comments there. This cluster's
# issuer/prefix is entirely independent of the hub's; a spoke pod's token
# can only ever validate against THIS provider, never the hub's.
locals {
  oidc_s3_prefix  = var.env
  oidc_issuer_url = "https://${data.terraform_remote_state.network.outputs.oidc_bucket_regional_domain_name}/${local.oidc_s3_prefix}"

  # EBS CSI pilot policy - straight copy of modules/ec2's worker_ebs
  # statements, attached to a role trusted only for the aws-ebs-csi-driver
  # controller ServiceAccount. See live/hub/main.tf's identical block for
  # the full rationale and the modules/ec2 TODO this is meant to replace.
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
        Sid    = "EBSMutateVolumeOnlyResourcesTaggedForThisCluster"
        Effect = "Allow"
        Action = [
          "ec2:DeleteVolume",
          "ec2:DeleteSnapshot",
          "ec2:ModifyVolume"
        ]
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

  # ── IRSA: AWS Cloud Controller Manager ──────────────────────────────────
  # Identical statements to live/hub's ccm_irsa_policy - see that file for
  # rationale. Kept as a separate local (not shared) since each cluster's
  # policy resolves var.cluster_name against its own root.
  ccm_irsa_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadOnlyDescribe"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeRegions",
          "ec2:DescribeRouteTables",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeVolumes",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInstanceTopology"
        ]
        Resource = "*"
      },
      {
        Sid      = "CreateSecurityGroupTaggedForThisCluster"
        Effect   = "Allow"
        Action   = "ec2:CreateSecurityGroup"
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
        }
      },
      {
        Sid    = "MutateOnlyResourcesTaggedForThisCluster"
        Effect = "Allow"
        Action = [
          "ec2:CreateTags",
          "ec2:DeleteSecurityGroup",
          "ec2:ModifyInstanceAttribute",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
        }
      },
      {
        Sid    = "ELBManageForCCMProvisionedLoadBalancers"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeLoadBalancerAttributes",
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:ModifyListener",
          "elasticloadbalancing:CreateTargetGroup",
          "elasticloadbalancing:DeleteTargetGroup",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetGroupAttributes",
          "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:DeregisterTargets",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:RegisterInstancesWithLoadBalancer",
          "elasticloadbalancing:DeregisterInstancesFromLoadBalancer",
          "elasticloadbalancing:CreateLoadBalancerListeners",
          "elasticloadbalancing:DeleteLoadBalancerListeners",
          "elasticloadbalancing:ConfigureHealthCheck",
          "elasticloadbalancing:AttachLoadBalancerToSubnets",
          "elasticloadbalancing:DetachLoadBalancerFromSubnets",
          "elasticloadbalancing:ApplySecurityGroupsToLoadBalancer",
          "elasticloadbalancing:SetLoadBalancerPoliciesOfListener",
          "elasticloadbalancing:CreateLoadBalancerPolicy",
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags",
          "elasticloadbalancing:DescribeTags",
          "ec2:DescribeVpcs"
        ]
        Resource = "*"
      }
    ]
  })

  # ── IRSA: Cilium ENI-mode IPAM (cilium-operator) ────────────────────────
  cilium_operator_irsa_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CiliumENIReadOnlyDescribe"
        Effect = "Allow"
        Action = [
          "ec2:DescribeSubnets",
          "ec2:DescribeVpcs",
          "ec2:DescribeVpcPeeringConnections",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeRouteTables",
          "ec2:DescribeTags"
        ]
        Resource = "*"
      },
      {
        Sid    = "CiliumENILifecycle"
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:AttachNetworkInterface",
          "ec2:DetachNetworkInterface",
          "ec2:DeleteNetworkInterface",
          "ec2:ModifyNetworkInterfaceAttribute",
          "ec2:AssignPrivateIpAddresses",
          "ec2:UnassignPrivateIpAddresses",
          "ec2:AssignIpv6Addresses",
          "ec2:UnassignIpv6Addresses"
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

  # ── IRSA: Karpenter (spoke only - hub runs no Karpenter, see modules/ec2's
  # install_karpenter). Straight copy of modules/ec2's worker_karpenter
  # statements, minus the ones that only made sense scoped to the whole
  # node role (SSM/EC2 read is unconditional there because every node
  # needed it for other things too - here it's just what Karpenter itself
  # needs). References module.ec2's worker role/profile ARNs directly
  # since Karpenter provisions new nodes under that exact role/profile.
  karpenter_irsa_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "KarpenterEC2ResourceDiscovery"
        Effect = "Allow"
        Action = [
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeCapacityReservations",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets"
        ]
        Resource = "*"
      },
      {
        Sid    = "KarpenterEC2Provisioning"
        Effect = "Allow"
        Action = [
          "ec2:CreateFleet",
          "ec2:CreateLaunchTemplate",
          "ec2:RunInstances"
        ]
        Resource = "*"
      },
      {
        Sid    = "KarpenterCreateTagsDuringProvisioning"
        Effect = "Allow"
        Action = [
          "ec2:CreateTags"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:fleet/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:launch-template/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:network-interface/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:spot-instances-request/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:volume/*"
        ]
        Condition = {
          StringEquals = {
            "ec2:CreateAction" = [
              "CreateFleet",
              "CreateLaunchTemplate",
              "RunInstances"
            ]
          }
        }
      },
      {
        Sid    = "KarpenterTagOwnedInstances"
        Effect = "Allow"
        Action = [
          "ec2:CreateTags"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
          StringLike = {
            "aws:ResourceTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        Sid    = "KarpenterTerminateOwnedInstances"
        Effect = "Allow"
        Action = [
          "ec2:TerminateInstances"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
          StringLike = {
            "aws:ResourceTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        Sid    = "KarpenterDeleteOwnedLaunchTemplates"
        Effect = "Allow"
        Action = [
          "ec2:DeleteLaunchTemplate"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:launch-template/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
          StringLike = {
            "aws:ResourceTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        Sid      = "KarpenterGetWorkerInstanceProfile"
        Effect   = "Allow"
        Action   = ["iam:GetInstanceProfile"]
        Resource = module.ec2.worker_iam_instance_profile_arn
      },
      {
        Sid      = "KarpenterListInstanceProfiles"
        Effect   = "Allow"
        Action   = ["iam:ListInstanceProfiles"]
        Resource = "*"
      },
      {
        Sid      = "KarpenterPassWorkerRole"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = module.ec2.worker_iam_role_arn
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ec2.amazonaws.com"
          }
        }
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
      }
    ]
  })
}

# ── VPC ───────────────────────────────────────────────────────────────────────
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

# ── Baked k8s base AMI (built by Packer + Ansible - see /packer) ─────────────
module "ami" {
  source = "../../modules/ami"
}

# ── Transit Gateway attachment - connects this VPC to the hub VPC ────────────
module "tgw_attachment" {
  source                = "../../modules/tgw-attachment"
  env                   = var.env
  transit_gateway_id    = data.terraform_remote_state.network.outputs.transit_gateway_id
  vpc_id                = module.vpc.vpc_id
  attachment_subnet_ids = module.vpc.private_subnet_ids
  route_table_ids       = [module.vpc.private_route_table_id, module.vpc.public_route_table_id]
  peer_cidr_blocks      = [var.hub_vpc_cidr]
}

# ── EC2: master node + shared IAM/SG resources ────────────────────────────────
# Moved above module.irsa (karpenter_irsa_policy needs module.ec2's worker
# role/profile ARN outputs).
module "ec2" {
  source                  = "../../modules/ec2"
  env                     = var.env
  vpc_id                  = module.vpc.vpc_id
  vpc_cidr                = var.vpc_cidr
  private_subnet_ids      = module.vpc.private_subnet_ids
  master_instance_type    = var.master_instance_type
  key_name                = var.key_name
  master_private_ip       = var.master_private_ip
  master_volume_size      = var.master_volume_size
  cluster_name            = var.cluster_name
  ami_id                  = module.ami.ami_id
  trusted_api_cidr_blocks = [var.hub_vpc_cidr]
  register_with_hub       = true
  vpc_cidr_supernet       = var.vpc_cidr_supernet
  clustermesh_nodeport    = var.clustermesh_nodeport
  oidc_bucket_arn         = data.terraform_remote_state.network.outputs.oidc_bucket_arn
  oidc_s3_prefix          = local.oidc_s3_prefix
}

# ── IRSA: register this cluster's OIDC issuer + workload roles ──────────────
module "irsa" {
  source          = "../../modules/irsa"
  cluster_prefix  = local.oidc_s3_prefix
  oidc_issuer_url = local.oidc_issuer_url

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

# ── K8s bootstrap scripts (kubeadm init + CNI only) ───────────────────────
module "k8s" {
  source            = "../../modules/k8s"
  k8s_version       = var.k8s_version
  env               = var.env
  vpc_cidr_supernet = var.vpc_cidr_supernet
  install_cni_ccm   = false # Argo CD (hub) installs CNI/CCM after this spoke registers
  oidc_issuer_url   = local.oidc_issuer_url
  oidc_s3_bucket    = data.terraform_remote_state.network.outputs.oidc_bucket_id
  oidc_s3_prefix    = local.oidc_s3_prefix
}

# ── ASG: worker node Auto Scaling Group ───────────────────────────────────────
module "asg" {
  source                           = "../../modules/asg"
  env                              = var.env
  cluster_name                     = var.cluster_name
  worker_instance_type             = var.worker_instance_type
  key_name                         = var.key_name
  private_subnet_ids               = module.vpc.private_subnet_ids
  worker_sg_id                     = module.ec2.worker_sg_id
  worker_iam_instance_profile_name = module.ec2.worker_iam_instance_profile_name
  k8s_worker_bootstrap             = module.k8s.worker_userdata
  worker_min                       = var.worker_min
  worker_max                       = var.worker_max
  worker_desired                   = var.worker_desired
  worker_volume_size               = var.worker_volume_size
  ami_id                           = module.ami.ami_id

  depends_on = [module.vpc]
}

# ── IRSA: External Secrets Operator (clustermesh CA pull only) ──────────────
# Replaces install_clustermesh_ca_pull's node instance-profile grant
# (modules/ec2, now removed) that platform/clustermesh/spoke/
# external-secret.yaml relied on implicitly.
locals {
  eso_irsa_policy_spoke = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "PullClustermeshCA"
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ]
      Resource = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:clustermesh/*"
    }]
  })
}