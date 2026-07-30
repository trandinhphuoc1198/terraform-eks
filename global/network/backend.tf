terraform {
  required_version = ">= 1.5.0"

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
  }
}

provider "aws" {
  region = var.region
}
