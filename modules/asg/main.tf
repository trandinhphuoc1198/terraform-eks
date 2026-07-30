# ── modules/asg/main.tf ────────────────────────────────────────────────────────
# Manages the worker node Auto Scaling Group (ASG) and Launch Template.
# Cluster Autoscaler discovers this ASG via the two required tags:
#   k8s.io/cluster-autoscaler/enabled
#   k8s.io/cluster-autoscaler/<cluster-name>

# ── Launch Template ────────────────────────────────────────────────────────────
resource "aws_launch_template" "worker" {
  name_prefix = "${var.env}-k8s-worker-"
  # AMI is the shared, Packer-built k8s base image (containerd/kubeadm/
  # kubelet/kubectl + node prep baked in) - see /packer and modules/ami.
  # Same image the master (modules/ec2) launches from. No dynamic SSM
  # lookup here anymore.
  image_id      = var.ami_id
  instance_type = var.worker_instance_type
  key_name      = var.key_name

  iam_instance_profile {
    name = var.worker_iam_instance_profile_name
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [var.worker_sg_id]
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.worker_volume_size
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  user_data = base64encode(var.k8s_worker_bootstrap)

  # Always use the latest version so ASG picks up AMI/config changes
  lifecycle {
    create_before_destroy = true
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.env}-k8s-worker"
      Role = "worker"
      Env  = var.env
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name = "${var.env}-k8s-worker-vol"
      Env  = var.env
    }
  }

  tags = { Name = "${var.env}-k8s-worker-lt", Env = var.env }
}

# ── Auto Scaling Group ─────────────────────────────────────────────────────────
resource "aws_autoscaling_group" "workers" {
  name                      = "${var.env}-k8s-workers"
  min_size                  = var.worker_min
  max_size                  = var.worker_max
  desired_capacity          = var.worker_desired
  vpc_zone_identifier       = var.private_subnet_ids
  health_check_type         = "EC2"
  health_check_grace_period = 300

  # Prefer AZ balance; fall back to capacity on scale-out
  default_cooldown = 120

  launch_template {
    id      = aws_launch_template.worker.id
    version = "$Latest"
  }

  # Instance refresh - rolling update when launch template changes
  # (including when a new Packer-built AMI shows up via modules/ami).
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  # Required tags for Cluster Autoscaler auto-discovery
  tag {
    key                 = "k8s.io/cluster-autoscaler/enabled"
    value               = "true"
    propagate_at_launch = true
  }

  tag {
    key                 = "k8s.io/cluster-autoscaler/${var.cluster_name}"
    value               = "owned"
    propagate_at_launch = true
  }

  tag {
    key                 = "Name"
    value               = "${var.env}-k8s-worker"
    propagate_at_launch = true
  }

  tag {
    key                 = "Role"
    value               = "worker"
    propagate_at_launch = true
  }

  tag {
    key                 = "Env"
    value               = var.env
    propagate_at_launch = true
  }

  tag {
    key                 = "kubernetes.io/cluster/${var.cluster_name}"
    value               = "owned"
    propagate_at_launch = true
  }

  lifecycle {
    ignore_changes = [desired_capacity] # Cluster Autoscaler manages desired after initial apply
  }
}
