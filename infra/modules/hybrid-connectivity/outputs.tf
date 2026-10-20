output "vpc_id" {
  description = "ID of the dedicated remote Region VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR of the dedicated remote Region VPC."
  value       = aws_vpc.this.cidr_block
}

output "node_subnet_ids" {
  description = "Hybrid node subnet IDs keyed by subnet name."
  value       = { for name, subnet in aws_subnet.nodes : name => subnet.id }
}

output "node_route_table_ids" {
  description = "Hybrid node route table IDs keyed by subnet name."
  value       = { for name, route_table in aws_route_table.nodes : name => route_table.id }
}

output "egress_subnet_id" {
  description = "Public subnet ID that hosts the remote NAT Gateway."
  value       = aws_subnet.egress.id
}

output "nat_gateway_id" {
  description = "NAT Gateway used by private hybrid node subnets."
  value       = aws_nat_gateway.this.id
}

output "hybrid_node_security_group_id" {
  description = "Shared security group for hybrid nodes."
  value       = aws_security_group.hybrid_nodes.id
}

output "availability_zones" {
  description = "Availability Zones keyed by hybrid node subnet name."
  value       = { for name, subnet in aws_subnet.nodes : name => subnet.availability_zone }
}

output "vpc_peering_connection_id" {
  description = "ID of the inter-Region VPC peering connection."
  value       = aws_vpc_peering_connection.remote_to_cluster.id
}

output "ssm_activation_id" {
  description = "Systems Manager hybrid activation ID."
  value       = aws_ssm_activation.hybrid_nodes.id
  sensitive   = true
}

output "ssm_activation_code" {
  description = "Short-lived Systems Manager hybrid activation code."
  value       = aws_ssm_activation.hybrid_nodes.activation_code
  sensitive   = true
}