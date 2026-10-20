resource "aws_ec2_availability_zone_group" "selected" {
  for_each = var.zone_group_names

  group_name    = each.value
  opt_in_status = "opted-in"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, { Name = "${var.name}-vpc" })
}

# Remove the default security group's rules so nothing attached to it by
# accident gains network access.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-default-deny" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-igw" })
}

resource "aws_subnet" "egress" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.egress_subnet.cidr
  availability_zone       = local.egress_subnet_availability_zone
  map_public_ip_on_launch = false

  tags = merge(var.tags, { Name = "${var.name}-egress" })
}

resource "aws_route_table" "egress" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-egress" })
}

resource "aws_route" "egress_internet" {
  route_table_id         = aws_route_table.egress.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "egress" {
  subnet_id      = aws_subnet.egress.id
  route_table_id = aws_route_table.egress.id
}

resource "aws_nat_gateway" "this" {
  allocation_id = var.nat_eip_allocation_id
  subnet_id     = aws_subnet.egress.id

  depends_on = [aws_route.egress_internet]
  tags       = merge(var.tags, { Name = "${var.name}-nat" })
}

resource "aws_subnet" "nodes" {
  for_each = local.node_subnets

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.availability_zone
  map_public_ip_on_launch = false

  depends_on = [aws_ec2_availability_zone_group.selected]
  tags       = merge(var.tags, { Name = "${var.name}-${each.key}" })
}

resource "aws_route_table" "nodes" {
  for_each = local.node_subnets

  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-${each.key}" })
}

resource "aws_route" "node_egress" {
  for_each = aws_route_table.nodes

  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "nodes" {
  for_each = aws_subnet.nodes

  subnet_id      = each.value.id
  route_table_id = aws_route_table.nodes[each.key].id
}

resource "aws_ssm_activation" "hybrid_nodes" {
  provider = aws.cluster

  name               = "${var.cluster_name}-remote-hybrid-nodes"
  description        = "EKS Hybrid Nodes activation for the experimental remote Region"
  iam_role           = var.hybrid_node_role_name
  registration_limit = var.ssm_activation_registration_limit
  tags               = var.tags
}
resource "aws_vpc_peering_connection" "remote_to_cluster" {
  vpc_id      = aws_vpc.this.id
  peer_vpc_id = var.cluster_vpc_id
  peer_region = var.cluster_region

  tags = merge(var.tags, { Name = "${var.name}-to-cluster" })
}

resource "aws_vpc_peering_connection_accepter" "cluster" {
  provider = aws.cluster

  vpc_peering_connection_id = aws_vpc_peering_connection.remote_to_cluster.id
  auto_accept               = true
  tags                      = merge(var.tags, { Name = "${var.name}-cluster-accepter" })
}

resource "aws_vpc_peering_connection_options" "remote" {
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.cluster.id

  requester {
    allow_remote_vpc_dns_resolution = true
  }
}

resource "aws_vpc_peering_connection_options" "cluster" {
  provider = aws.cluster

  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.cluster.id

  accepter {
    allow_remote_vpc_dns_resolution = true
  }
}

resource "aws_route" "remote_to_cluster" {
  for_each = aws_route_table.nodes

  route_table_id            = each.value.id
  destination_cidr_block    = var.cluster_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.remote_to_cluster.id

  depends_on = [aws_vpc_peering_connection_accepter.cluster]
}

resource "aws_route" "cluster_to_remote" {
  provider = aws.cluster
  for_each = {
    for index, route_table_id in var.cluster_route_table_ids : tostring(index) => route_table_id
  }

  route_table_id            = each.value
  destination_cidr_block    = var.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.remote_to_cluster.id

  depends_on = [aws_vpc_peering_connection_accepter.cluster]
}

resource "aws_security_group" "hybrid_nodes" {
  name_prefix            = "${var.name}-hybrid-nodes-"
  description            = "Network access for experimental EKS hybrid nodes"
  vpc_id                 = aws_vpc.this.id
  revoke_rules_on_delete = true

  tags = merge(var.tags, { Name = "${var.name}-hybrid-nodes" })
}

resource "aws_vpc_security_group_ingress_rule" "kubelet" {
  security_group_id = aws_security_group.hybrid_nodes.id
  description       = "EKS control plane and cluster nodes to kubelet"
  cidr_ipv4         = var.cluster_vpc_cidr
  from_port         = 10250
  to_port           = 10250
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "node_self" {
  security_group_id            = aws_security_group.hybrid_nodes.id
  description                  = "Traffic among remote hybrid nodes"
  referenced_security_group_id = aws_security_group.hybrid_nodes.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "inference" {
  security_group_id = aws_security_group.hybrid_nodes.id
  description       = "Core cluster nodes to remote inference endpoints"
  cidr_ipv4         = var.cluster_vpc_cidr
  from_port         = var.inference_port
  to_port           = var.inference_port
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.hybrid_nodes.id
  description       = "Outbound bootstrap, AWS service, registry, and cluster access"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}