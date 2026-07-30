# Module: `vpc`

Provisions the **network foundation** for the Kubernetes cluster - a VPC with
public and private subnets across two availability zones, internet egress
for both tiers via an AWS-managed NAT Gateway, a private gateway into S3,
and private connectivity to SSM for master/worker access.

---

## Resources created

| Resource | Name pattern | Purpose |
|---|---|---|
| `aws_vpc` | `${env}-k8s-vpc` | Main VPC with DNS support enabled |
| `aws_internet_gateway` | `${env}-igw` | Internet access for public subnets |
| `aws_subnet` (×N) | `${env}-public-subnet-{n}` | One per entry in `public_subnet_cidrs` |
| `aws_subnet` (×N) | `${env}-private-subnet-{n}` | One per entry in `private_subnet_cidrs` - hosts the master node and worker nodes (no public IPs) |
| `aws_eip` | `${env}-nat-eip` | Elastic IP for the NAT Gateway |
| `aws_nat_gateway` | `${env}-nat-gateway` | AWS-managed NAT Gateway in the first public subnet, serving all private subnets |
| `aws_vpc_endpoint` | `${env}-s3-endpoint` | Gateway endpoint - private/free S3 traffic |
| `aws_security_group` | `${env}-vpc-endpoints-sg` | Allows HTTPS from the VPC to the SSM interface endpoints |
| `aws_vpc_endpoint` (×3) | `${env}-{ssm,ssmmessages,ec2messages}-endpoint` | Interface endpoints - let SSM Session Manager reach the master/workers privately |
| `aws_route_table` | `${env}-public-rt` | Routes public subnets to the IGW |
| `aws_route_table` | `${env}-private-rt` | Routes private subnets through the NAT Gateway; tagged `kubernetes.io/cluster/<cluster_name>=owned` so AWS CCM's route controller can find it |
| `aws_route` | - | Private subnets' `0.0.0.0/0` route via the NAT Gateway |
| `aws_route_table_association` (×N) | - | Associates each subnet with its route table |

---

## Design notes

**Two-tier subnet layout**

Private subnets host both the master node and worker nodes - neither has a
public IP and neither is reachable from the internet inbound. Access to the
master is via SSM Session Manager (see below) or VPC-internal SSH only.
Public subnets currently have no in-VPC resource attached to them by this
module beyond the NAT Gateway itself (see the root README's "Ingress note"
- there is no Terraform-managed ALB using these public subnets today).

**NAT Gateway**

A single AWS-managed NAT Gateway (with its own Elastic IP) in the first
public subnet serves all private subnets. This is a managed AWS resource,
not an EC2 instance - there is no `wait_for_nat` step needed before worker
or master instances launch.

**S3 VPC Endpoint (Gateway type)**

Traffic between worker nodes and S3 stays within the AWS network and does
not traverse the NAT Gateway. This reduces data transfer costs and improves
throughput for workloads that read from or write to S3.

**SSM VPC Interface Endpoints**

Since the master has no public IP and SSH is VPC-only, `aws ssm
start-session` is the primary way to reach it. Three interface endpoints
(`ssm`, `ssmmessages`, `ec2messages`) let SSM Agent reach Session Manager
without depending on the NAT Gateway's route to the internet - all three
are required together for the agent to function. They share one security
group (`${env}-vpc-endpoints-sg`) that accepts HTTPS from anywhere in the
VPC.

**Availability zones**

Subnets are distributed across AZs using the `aws_availability_zones` data
source, so the code does not hard-code AZ names and works in any region.

**Cluster Mesh tagging**

The private route table carries
`kubernetes.io/cluster/${var.cluster_name} = owned` - the same tag/value
convention used on ASG/instance resources in `modules/ec2` and
`modules/asg`. AWS Cloud Controller Manager's route controller
(`--configure-cloud-routes=true`) discovers this table via that tag to sync
per-node pod-CIDR routes for Cilium's native-routing mode.

---

## Variables

| Name | Type | Description |
|---|---|---|
| `env` | `string` | Environment name - used as a name prefix for all resources |
| `vpc_cidr` | `string` | CIDR block for the VPC (e.g. `10.0.0.0/16`) |
| `public_subnet_cidrs` | `list(string)` | One CIDR per public subnet (must be within `vpc_cidr`) |
| `private_subnet_cidrs` | `list(string)` | One CIDR per private subnet (must be within `vpc_cidr`) |
| `region` | `string` | AWS region - used to construct the S3 and SSM endpoint service names |
| `cluster_name` | `string` | K8s cluster name - tags the private route table so AWS CCM's route controller can discover it for native-routing pod-CIDR sync |

---

## Outputs

| Name | Description |
|---|---|
| `vpc_id` | ID of the created VPC |
| `vpc_cidr` | CIDR block of the created VPC |
| `public_subnet_ids` | List of public subnet IDs |
| `private_subnet_ids` | List of private subnet IDs (used by the master and ASG worker nodes) |
| `nat_gateway_id` | ID of the NAT Gateway |
| `nat_gateway_public_ip` | Public IP of the NAT Gateway (its Elastic IP) |
| `public_route_table_id` | Public route table ID - used by `tgw-attachment` |
| `private_route_table_id` | Private route table ID - used by `tgw-attachment` |
| `vpc_endpoints_sg_id` | Security group ID shared by the SSM interface endpoints - useful for debugging connectivity |
