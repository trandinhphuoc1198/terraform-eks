output "ami_id" {
  description = "ID of the most recent baked k8s base AMI - pass to modules/ec2 and modules/asg"
  value       = data.aws_ami.k8s_base.id
}
