output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "Feed this into live/hub's spoke_vpc_cidrs list"
  value       = module.vpc.vpc_cidr
}

output "tgw_attachment_id" {
  value = module.tgw_attachment.attachment_id
}

output "cluster_name" {
  value = var.cluster_name
}

output "irsa_role_arns" {
  description = "Map of role_key -> IAM role ARN from modules/irsa. Annotate the matching ServiceAccount in the gitops repo with eks.amazonaws.com/role-arn = this value (e.g. irsa_role_arns[\"ebs-csi-controller\"] -> aws-ebs-csi-driver's ebs-csi-controller-sa)."
  value       = module.irsa.role_arns
}

output "argocd_registration_ci_role_arn" {
  value = aws_iam_role.argocd_registration_ci.arn
}

output "karpenter_node_role_name" {
  description = "Pass this to platform/karpenter/spoke's EC2NodeClass.spec.role via the ApplicationSet's helm.parameters"
  value       = module.eks_node_role_karpenter.role_name
}