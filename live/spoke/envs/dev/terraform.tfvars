env          = "spoke-dev"
region       = "ap-northeast-1"
cluster_name = "spoke-dev-k8s"

# Distinct address space from the hub - required for TGW routing.
vpc_cidr             = "10.1.0.0/16"
public_subnet_cidrs  = ["10.1.1.0/24", "10.1.2.0/24"]
private_subnet_cidrs = ["10.1.11.0/24", "10.1.12.0/24"]

# Must match live/hub's vpc_cidr.
hub_vpc_cidr = "10.0.0.0/16"

master_instance_type = "c7i-flex.large"
worker_instance_type = "c7i-flex.large"

worker_min         = 1
worker_max         = 3
worker_desired     = 1
worker_volume_size = 20

eks_cluster_version = "1.33"
