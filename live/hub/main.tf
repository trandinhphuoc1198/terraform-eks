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

check "no_duplicate_cidrs" {
  assert {
    condition     = length(local.cidr_ranges) == length(concat([var.vpc_cidr], var.spoke_vpc_cidrs))
    error_message = "vpc_cidr and spoke_vpc_cidrs contain an exact duplicate CIDR - each cluster needs a distinct VPC CIDR."
  }
}

# ── IRSA / OIDC ─────────────────────────────────────────────────────────────
# This cluster's own prefix inside the shared bucket from global/network.
# cluster_prefix intentionally reuses var.env (e.g. "hub-dev") - same value
# already used as modules/k8s's "env" and as the S3 key prefix for the
# join-token SSM parameter, so there's one name for "this cluster" across
# the whole repo, not a second parallel identifier to keep in sync.
locals {
  oidc_s3_prefix  = var.env
  oidc_issuer_url = "https://${data.terraform_remote_state.network.outputs.oidc_bucket_regional_domain_name}/${local.oidc_s3_prefix}"

  # EBS CSI pilot policy - deliberately a straight copy of modules/ec2's
  # worker_ebs statements (same tag-scoping pattern), just attached to a
  # role trusted only for the aws-ebs-csi-driver controller ServiceAccount
  # instead of the whole node. Once this is verified working (see
  # modules/irsa/README.md's "Adding a new workload" checklist), the
  # equivalent statements get removed from modules/ec2/main.tf's
  # worker_ebs policy - see the TODO left there.
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
  enable_karpenter_discovery = false
}

# ── Baked k8s base AMI (built by Packer + Ansible - see /packer) ─────────────
module "ami" {
  source = "../../modules/ami"
}

# ── Transit Gateway attachment - connects this VPC to every spoke VPC ────────
module "tgw_attachment" {
  source                = "../../modules/tgw-attachment"
  env                   = var.env
  transit_gateway_id    = data.terraform_remote_state.network.outputs.transit_gateway_id
  vpc_id                = module.vpc.vpc_id
  attachment_subnet_ids = module.vpc.private_subnet_ids
  route_table_ids       = [module.vpc.private_route_table_id, module.vpc.public_route_table_id]
  peer_cidr_blocks      = var.spoke_vpc_cidrs
}

# ── IRSA: register this cluster's OIDC issuer + the EBS CSI pilot role ──────
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
      policy_json     = local.eso_irsa_policy_hub
    }
  }
}

# ── K8s bootstrap scripts (kubeadm init + CNI only) ───────────────────────
module "k8s" {
  source            = "../../modules/k8s"
  k8s_version       = var.k8s_version
  env               = var.env
  vpc_cidr_supernet = var.vpc_cidr_supernet
  install_cni_ccm   = true # Argo CD runs here - can't install its own dependency
  oidc_issuer_url   = local.oidc_issuer_url
  oidc_s3_bucket    = data.terraform_remote_state.network.outputs.oidc_bucket_id
  oidc_s3_prefix    = local.oidc_s3_prefix
}

# ── EC2: master node + shared IAM/SG resources ────────────────────────────────
module "ec2" {
  source               = "../../modules/ec2"
  env                  = var.env
  vpc_id               = module.vpc.vpc_id
  vpc_cidr             = var.vpc_cidr
  private_subnet_ids   = module.vpc.private_subnet_ids
  master_instance_type = var.master_instance_type
  key_name             = var.key_name
  master_private_ip    = var.master_private_ip
  master_volume_size   = var.master_volume_size
  cluster_name         = var.cluster_name
  ami_id               = module.ami.ami_id
  s3_bucket_arns       = module.s3.bucket_arns
  install_karpenter    = false
  vpc_cidr_supernet    = var.vpc_cidr_supernet
  clustermesh_nodeport = var.clustermesh_nodeport
  oidc_bucket_arn      = data.terraform_remote_state.network.outputs.oidc_bucket_arn
  oidc_s3_prefix       = local.oidc_s3_prefix
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

# ── S3 Buckets ─────────────────────────────────────────────────────────────────
module "s3" {
  source       = "../../modules/s3"
  bucket_names = var.bucket_names
  env          = var.env
}

# ── IAM role assumed by the verify-spoke-registration.yml GitHub Actions workflow ─
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_caller_identity" "current" {}

# ── IRSA: External Secrets Operator ─────────────────────────────────────────
# Combines BOTH of ESO's previous credential paths on hub into one role
# (one ESO controller Pod/SA backs both SecretStores):
#   - argocd-clusters-store used a static "eso-secrets-reader" IAM user +
#     aws-creds Secret, seeded by the now-removed
#     .github/scripts/bootstrap-eso-secret.sh.tpl
#   - clustermesh-secrets-store relied on the node's EC2 instance-profile
#     role (install_clustermesh_ca_push on modules/ec2, now removed)
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
        Sid      = "FindHubMaster"
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances"]
        Resource = "*"
      },
      {
        Sid    = "RunOnHubMasterOnly"
        Effect = "Allow"
        Action = ["ssm:SendCommand"]
        Resource = [
          module.ec2.master_instance_arn,
          "arn:aws:ssm:${var.region}::document/AWS-RunShellScript"
        ]
      },
      {
        Sid      = "ReadCommandResults"
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation", "ssm:ListCommands", "ssm:ListCommandInvocations"]
        Resource = "*"
      },
      {
        Sid    = "ReadSpokeRegistrationSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue"
        ]
        Resource = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:argocd-clusters/*"
      }
    ]
  })
}
output "argocd_registration_ci_role_arn" {
  value = aws_iam_role.argocd_registration_ci.arn
}
