# ── CIDR overlap guard ─────────────────────────────────────────────────────
locals {
  cidr_ranges = {
    for c in [var.vpc_cidr, var.hub_vpc_cidr] : c => {
      start = sum([for i, o in split(".", cidrhost(c, 0)) : tonumber(o) * pow(256, 3 - i)])
      end   = sum([for i, o in split(".", cidrhost(c, 0)) : tonumber(o) * pow(256, 3 - i)]) + pow(2, 32 - tonumber(split("/", c)[1])) - 1
    }
  }
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
    condition = !(
      local.cidr_ranges[var.vpc_cidr].start <= local.cidr_ranges[var.hub_vpc_cidr].end &&
      local.cidr_ranges[var.hub_vpc_cidr].start <= local.cidr_ranges[var.vpc_cidr].end
    )
    error_message = "vpc_cidr (${var.vpc_cidr}) and hub_vpc_cidr (${var.hub_vpc_cidr}) overlap - they must be disjoint for TGW routing to work."
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

# ── Transit Gateway attachment - connects this VPC to the hub VPC ────────────
module "tgw_attachment" {
  source                     = "../../modules/tgw-attachment"
  env                        = var.env
  transit_gateway_id         = data.terraform_remote_state.network.outputs.transit_gateway_id
  vpc_id                     = module.vpc.vpc_id
  attachment_subnet_ids      = module.vpc.private_subnet_ids
  route_table_ids            = [module.vpc.private_route_table_id, module.vpc.public_route_table_id]
  peer_cidr_blocks           = [var.hub_vpc_cidr]
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
  install_cni_ccm   = false # Argo CD (hub) installs CNI/CCM after this spoke registers
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
  trusted_api_cidr_blocks     = [var.hub_vpc_cidr]
  register_with_hub           = true
  install_clustermesh_ca_pull = true
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

