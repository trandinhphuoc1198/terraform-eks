output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_arn" {
  value = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "kube-apiserver endpoint - feed into kubeconfig / `aws eks update-kubeconfig`"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  value = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_oidc_issuer_url" {
  description = "This cluster's built-in OIDC issuer - pass straight into modules/irsa's oidc_issuer_url. No modules/oidc-bucket needed anymore; EKS hosts this itself."
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "cluster_security_group_id" {
  description = "EKS's own auto-created control-plane security group (node<->control-plane traffic). Attach this to node groups/Karpenter EC2NodeClasses in addition to any custom SGs."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "cluster_additional_security_group_id" {
  value = aws_security_group.cluster_additional.id
}

output "cluster_role_arn" {
  value = aws_iam_role.cluster.arn
}

output "cluster_version" {
  value = aws_eks_cluster.this.version
}
