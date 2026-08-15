terraform {
  required_version = ">= 1.5.0"

  # `key` is intentionally omitted - passed at `terraform init` time via
  # -backend-config so this file is identical across every environment.
  # See envs/<env>/backend.hcl.
  backend "s3" {
    bucket       = "terraform-phuoctd6"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    # Used by modules/irsa to fetch the OIDC issuer's TLS certificate
    # thumbprint for aws_iam_openid_connect_provider.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# One-directional only: global/network has no dependency back on hub or
# spoke, so this is safe to read any time as long as global/network was
# applied first (see root README for apply order).
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "terraform-phuoctd6"
    key    = var.network_state_key
    region = "us-east-1"
  }
}

# Auths against the hub cluster using the same identity that ran
# `terraform apply` (bootstrap_cluster_creator_admin_permissions = true on
# module.eks gives it implicit cluster-admin - no separate access entry
# needed here, same reasoning k8s-cluster-bootstrap.yml's old inline
# install relied on).
data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}