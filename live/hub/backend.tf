terraform {
  required_version = ">= 1.5.0"

  # `key` is intentionally omitted - passed at `terraform init` time via
  # -backend-config so this file is identical across every environment.
  # See envs/<env>/backend.hcl.
  backend "s3" {
    bucket       = "terraform-state-phuoctd6"
    region       = "ap-northeast-1"
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
    bucket = "terraform-state-phuoctd6"
    key    = var.network_state_key
    region = "ap-northeast-1"
  }
}
