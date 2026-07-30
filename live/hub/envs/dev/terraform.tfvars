env          = "hub-dev"
region       = "ap-northeast-1"
cluster_name = "hub-dev-k8s"

# Distinct address space from every spoke - required for the TGW routing
# to work (overlapping CIDRs cannot be routed between via TGW).
vpc_cidr             = "10.0.0.0/16"
public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
private_subnet_cidrs = ["10.0.11.0/24", "10.0.12.0/24"]

# Populate once the spoke VPC exists (see README bootstrap order).
# Add one entry per spoke as your fleet grows.
spoke_vpc_cidrs = ["10.1.0.0/16"]

master_instance_type = "c7i-flex.large"
worker_instance_type = "m7i-flex.large"
key_name             = "key"
master_private_ip    = "10.0.11.10"

worker_min         = 1
worker_max         = 3
worker_desired     = 1
worker_volume_size = 20
master_volume_size = 20

k8s_version = "1.33.2"
pod_cidr    = "100.64.0.0/16"

bucket_names = [
  "tempo-s3-phuoctd6",
  "log-s3-phuoctd6"
]