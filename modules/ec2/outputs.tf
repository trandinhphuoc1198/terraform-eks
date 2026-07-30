output "master_private_ip" {
  value = aws_instance.master.private_ip
}

output "master_instance_id" {
  description = "EC2 instance ID of the master - use `aws ssm start-session --target <id>` to reach it (no public IP, SSH is VPC-only fallback)"
  value       = aws_instance.master.id
}

output "master_sg_id" {
  description = "Security group ID of the master node"
  value       = aws_security_group.master.id
}

output "worker_sg_id" {
  description = "Security group ID shared by all worker nodes launched by the ASG (modules/asg) - attached to every worker instance via the launch template"
  value       = aws_security_group.worker.id
}

output "worker_iam_instance_profile_name" {
  description = "Instance profile name for worker nodes - used by ASG launch template"
  value       = aws_iam_instance_profile.worker.name
}

output "ssm_join_token_arn" {
  description = "ARN of the SSM parameter storing the kubeadm join token"
  value       = aws_ssm_parameter.cluster_join_token.arn
}

output "master_instance_arn" {
  description = "ARN of the master EC2 instance - used to scope the CI role's ssm:SendCommand permission to this instance only"
  value       = aws_instance.master.arn
}
