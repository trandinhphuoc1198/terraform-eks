# Split out from modules/eks-node-group deliberately. EKS's API auth mode
# requires an access entry for a node role to exist BEFORE any EC2 instance
# using that role tries to join the cluster - if the role and the node group
# were created inside the same module, nothing would force the access entry
# (created by the caller, referencing this module's output) to land first,
# and Managed Node Group instances could come up stuck NotReady with no
# obvious error. Callers are expected to:
#   1. Instantiate this module (creates the role only, no compute).
#   2. Create an aws_eks_access_entry for role_arn.
#   3. Create the node group / EC2NodeClass with an explicit depends_on the
#      access entry.
# See live/hub/main.tf and live/spoke/main.tf for the actual sequencing.

resource "aws_iam_role" "this" {
  name = "${var.env}-eks-${var.role_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${var.env}-eks-${var.role_name}-node-role", Env = var.env }
}

# Deliberately NOT attaching AmazonEKS_CNI_Policy - that grants the
# ENI/IP-assignment permissions the AWS VPC CNI's IPAMD needs, and this
# fleet replaces vpc-cni with Cilium entirely (cilium-operator does its own
# ENI IPAM via its own IRSA role, not the node role).
resource "aws_iam_role_policy_attachment" "worker_node_policy" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "ecr_read_only" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Same access path the kubeadm master/workers used (aws ssm start-session) -
# kept for debugging parity.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
