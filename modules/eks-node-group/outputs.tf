output "node_group_id" {
  value = aws_eks_node_group.this.id
}

output "node_group_status" {
  value = aws_eks_node_group.this.status
}
