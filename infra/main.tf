# The remote NAT Gateway address is allocated here rather than inside
# hybrid-connectivity so that cluster-region can admit it to the public EKS API
# endpoint allowlist. Allocating it in hybrid-connectivity would create a
# dependency cycle, because that module already consumes the cluster VPC and its
# route tables. An Elastic IP allocation depends on nothing else, so hoisting it
# keeps the whole sample a single apply.
resource "aws_eip" "remote_nat" {
  provider = aws.remote
  domain   = "vpc"

  tags = merge(local.tags, { Name = "${var.cluster_name}-remote-nat" })
}

module "cluster_region" {
  source = "./modules/cluster-region"

  providers = {
    aws = aws.cluster
  }

  cluster_name                             = var.cluster_name
  kubernetes_version                       = var.kubernetes_version
  vpc_cidr                                 = var.cluster_vpc_cidr
  availability_zone_count                  = var.availability_zone_count
  single_nat_gateway                       = var.single_nat_gateway
  endpoint_private_access                  = var.endpoint_private_access
  endpoint_public_access_cidrs             = var.endpoint_public_access_cidrs
  remote_nat_public_ip                     = aws_eip.remote_nat.public_ip
  enable_cluster_creator_admin_permissions = var.enable_cluster_creator_admin_permissions
  remote_node_cidrs                        = var.remote_node_cidrs
  remote_pod_cidrs                         = var.remote_pod_cidrs
  snat_exclude_cidrs                       = concat([var.remote_vpc_cidr], var.remote_pod_cidrs)
  core_node_instance_types                 = var.core_node_instance_types
  core_node_min_size                       = var.core_node_min_size
  core_node_desired_size                   = var.core_node_desired_size
  core_node_max_size                       = var.core_node_max_size
  enable_lb_controller                     = var.enable_lb_controller
  tags                                     = local.tags
}

module "hybrid_connectivity" {
  source = "./modules/hybrid-connectivity"

  providers = {
    aws         = aws.remote
    aws.cluster = aws.cluster
  }

  name                              = "${var.cluster_name}-remote"
  cluster_name                      = module.cluster_region.cluster_name
  cluster_region                    = var.cluster_region
  cluster_vpc_id                    = module.cluster_region.vpc_id
  cluster_vpc_cidr                  = module.cluster_region.vpc_cidr
  cluster_route_table_ids           = concat(module.cluster_region.private_route_table_ids, module.cluster_region.intra_route_table_ids)
  hybrid_node_role_name             = module.cluster_region.hybrid_node_role_name
  vpc_cidr                          = var.remote_vpc_cidr
  nat_eip_allocation_id             = aws_eip.remote_nat.id
  node_subnets                      = var.remote_node_subnets
  egress_subnet                     = var.remote_egress_subnet
  zone_group_names                  = var.remote_zone_group_names
  ssm_activation_registration_limit = var.ssm_activation_registration_limit
  tags                              = local.tags
}

module "hybrid_nodes" {
  source   = "./modules/hybrid-node"
  for_each = var.hybrid_nodes

  providers = {
    aws = aws.remote
  }

  name               = "${var.cluster_name}-${each.key}"
  cluster_name       = module.cluster_region.cluster_name
  cluster_region     = var.cluster_region
  kubernetes_version = var.kubernetes_version
  nodeadm_version    = var.nodeadm_version
  subnet_id          = module.hybrid_connectivity.node_subnet_ids[each.value.subnet_key]
  security_group_ids = [module.hybrid_connectivity.hybrid_node_security_group_id]
  instance_type      = each.value.instance_type
  ami_id             = each.value.ami_id
  root_volume_size   = each.value.root_volume_size
  node_labels = merge(
    {
      "sample.eks.aws/node-name" = each.key
    },
    each.value.node_labels
  )
  node_taints                   = each.value.node_taints
  ssm_activation_id             = module.hybrid_connectivity.ssm_activation_id
  ssm_activation_code           = module.hybrid_connectivity.ssm_activation_code
  capacity_block_reservation_id = each.value.capacity_block_reservation_id
  tags                          = local.tags

  depends_on = [module.hybrid_connectivity]
}