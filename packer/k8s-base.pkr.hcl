packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
    ansible = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

locals {
  timestamp = formatdate("YYYYMMDD-hhmmss", timestamp())
  ami_name  = "${var.ami_name_prefix}-k8s${var.k8s_version}-${local.timestamp}"
}

# Same AL2023 minimal AMI family that modules/ec2 and modules/asg used to
# resolve dynamically at apply time via the SSM public path. Packer builds
# FROM this base and layers the baked config on top.
data "amazon-ami" "al2023" {
  filters = {
    name = "al2023-ami-minimal-*-x86_64"
  }
  owners      = ["amazon"]
  most_recent = true
  region      = var.region
}


source "amazon-ebs" "k8s_base" {
  ami_name                    = local.ami_name
  instance_type               = var.instance_type
  region                      = var.region
  source_ami                  = data.amazon-ami.al2023.id
  subnet_id                   = var.subnet_id
  vpc_id                      = var.vpc_id
  ssh_username                = var.ssh_username
  associate_public_ip_address = true

  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tags = {
    Name               = local.ami_name
    purpose            = "k8s-base"
    kubernetes_version = var.k8s_version
    built_by           = "packer"
  }
}

build {
  sources = ["source.amazon-ebs.k8s_base"]

  provisioner "ansible" {
    playbook_file = "${path.root}/ansible/playbook.yml"
    extra_arguments = [
      "--extra-vars", "k8s_version=${var.k8s_version}"
    ]
  }
}
