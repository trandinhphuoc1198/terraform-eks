output "master_instance_id" {
  description = "aws ssm start-session --target <this> to grab the hub kubeconfig / check bootstrap logs (master has no public IP)"
  value       = module.ec2.master_instance_id
}

output "master_private_ip" {
  value = module.ec2.master_private_ip
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "Feed this into live/spoke's hub_vpc_cidr variable"
  value       = module.vpc.vpc_cidr
}

output "master_sg_id" {
  value = module.ec2.master_sg_id
}

output "tgw_attachment_id" {
  value = module.tgw_attachment.attachment_id
}

output "master_userdata" {
  description = "Bootstrap script content for the master node (kubeadm init + CNI). Consumed by k8s-cluster-bootstrap.yml via SSM send-command - not applied automatically as EC2 user_data."
  value       = module.k8s.master_userdata
}