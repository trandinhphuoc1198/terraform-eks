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

locals {
  pod_start      = sum([for i, o in split(".", cidrhost(var.pod_cidr, 0)) : tonumber(o) * pow(256, 3 - i)])
  pod_end        = local.pod_start + pow(2, 32 - tonumber(split("/", var.pod_cidr)[1])) - 1
  supernet_start = sum([for i, o in split(".", cidrhost(var.pod_cidr_supernet, 0)) : tonumber(o) * pow(256, 3 - i)])
  supernet_end   = local.supernet_start + pow(2, 32 - tonumber(split("/", var.pod_cidr_supernet)[1])) - 1
}

check "pod_cidr_within_fleet_supernet" {
  assert {
    condition     = local.pod_start >= local.supernet_start && local.pod_end <= local.supernet_end
    error_message = "pod_cidr (${var.pod_cidr}) must fall within pod_cidr_supernet (${var.pod_cidr_supernet}) for Cilium Cluster Mesh routing to work."
  }
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

# ── VPC ───────────────────────────────────────────────────────────────────────
module "vpc" {
  source               = "../../modules/vpc"
  env                  = var.env
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  region               = var.region
  cluster_name         = var.cluster_name
}

# ── Baked k8s base AMI (built by Packer + Ansible - see /packer) ─────────────
module "ami" {
  source = "../../modules/ami"
}

# ── Transit Gateway attachment - connects this VPC to every spoke VPC ────────
module "tgw_attachment" {
  source                     = "../../modules/tgw-attachment"
  env                        = var.env
  transit_gateway_id         = data.terraform_remote_state.network.outputs.transit_gateway_id
  vpc_id                     = module.vpc.vpc_id
  attachment_subnet_ids      = module.vpc.private_subnet_ids
  route_table_ids            = [module.vpc.private_route_table_id, module.vpc.public_route_table_id]
  peer_cidr_blocks           = var.spoke_vpc_cidrs
  own_pod_cidr               = var.pod_cidr
  pod_cidr_supernet          = var.pod_cidr_supernet
  tgw_default_route_table_id = data.terraform_remote_state.network.outputs.transit_gateway_default_route_table_id
}

# ── K8s bootstrap scripts (kubeadm init + CNI only) ───────────────────────
module "k8s" {
  source            = "../../modules/k8s"
  k8s_version       = var.k8s_version
  pod_cidr          = var.pod_cidr
  env               = var.env
  pod_cidr_supernet = var.pod_cidr_supernet
  install_cni_ccm   = true # Argo CD runs here - can't install its own dependency
}

# ── EC2: master node + shared IAM/SG resources ────────────────────────────────
module "ec2" {
  source                      = "../../modules/ec2"
  env                         = var.env
  vpc_id                      = module.vpc.vpc_id
  vpc_cidr                    = var.vpc_cidr
  private_subnet_ids          = module.vpc.private_subnet_ids
  master_instance_type        = var.master_instance_type
  key_name                    = var.key_name
  master_private_ip           = var.master_private_ip
  master_volume_size          = var.master_volume_size
  cluster_name                = var.cluster_name
  ami_id                      = module.ami.ami_id
  s3_bucket_arns              = module.s3.bucket_arns
  install_eso                 = true
  install_clustermesh_ca_push = true
  pod_cidr_supernet           = var.pod_cidr_supernet
  vpc_cidr_supernet           = var.vpc_cidr_supernet
  clustermesh_nodeport        = var.clustermesh_nodeport
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
        StringLike   = { "token.actions.githubusercontent.com:sub" = "repo:trandinhphuoc1198/*:*" }
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