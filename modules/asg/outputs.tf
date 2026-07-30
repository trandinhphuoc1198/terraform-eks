output "asg_name" {
  description = "Name of the worker Auto Scaling Group"
  value       = aws_autoscaling_group.workers.name
}

output "launch_template_id" {
  description = "ID of the worker launch template"
  value       = aws_launch_template.worker.id
}
