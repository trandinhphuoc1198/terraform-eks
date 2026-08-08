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

output "irsa_role_arns" {
  description = "Map of role_key -> IAM role ARN from modules/irsa. Annotate the matching ServiceAccount in the gitops repo with eks.amazonaws.com/role-arn = this value (e.g. irsa_role_arns[\"ebs-csi-controller\"] -> aws-ebs-csi-driver's ebs-csi-controller-sa)."
  value       = module.irsa.role_arns
}
