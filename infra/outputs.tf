output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = module.cluster_region.cluster_name
}

output "cluster_region" {
  description = "AWS Region that contains the EKS cluster."
  value       = var.cluster_region
}

output "cluster_endpoint" {
  description = "Endpoint for the EKS Kubernetes API server."
  value       = module.cluster_region.cluster_endpoint
  sensitive   = true
}

output "cluster_vpc_id" {
  description = "ID of the cluster Region VPC."
  value       = module.cluster_region.vpc_id
}

output "cluster_private_route_table_ids" {
  description = "Private route table IDs that receive routes to the remote VPC through peering."
  value       = module.cluster_region.private_route_table_ids
}

output "cluster_intra_route_table_ids" {
  description = "Control-plane route table IDs that receive routes to the remote VPC through peering."
  value       = module.cluster_region.intra_route_table_ids
}

output "hybrid_node_role_arn" {
  description = "IAM role ARN used to authenticate remote hybrid nodes."
  value       = module.cluster_region.hybrid_node_role_arn
}

output "configure_kubectl" {
  description = "Command that updates kubeconfig for the cluster."
  value       = "aws eks update-kubeconfig --region ${var.cluster_region} --name ${module.cluster_region.cluster_name}"
}

output "remote_vpc_id" {
  description = "ID of the experimental remote Region VPC."
  value       = module.hybrid_connectivity.vpc_id
}

output "remote_egress_subnet_id" {
  description = "ID of the public remote subnet that hosts the NAT Gateway."
  value       = module.hybrid_connectivity.egress_subnet_id
}

output "remote_nat_gateway_id" {
  description = "ID of the NAT Gateway used by private hybrid-node subnets."
  value       = module.hybrid_connectivity.nat_gateway_id
}

output "remote_nat_public_ip" {
  description = "Public address of the remote NAT Gateway. Hybrid nodes reach the public EKS API endpoint from here, so Terraform admits it to endpoint_public_access_cidrs automatically."
  value       = aws_eip.remote_nat.public_ip
}

output "remote_hybrid_nodes" {
  description = "EC2 hybrid node identifiers, private IPs, and Availability Zones keyed by node name."
  value = {
    for name, node in module.hybrid_nodes : name => {
      instance_id       = node.instance_id
      private_ip        = node.private_ip
      availability_zone = node.availability_zone
    }
  }
}

output "vpc_peering_connection_id" {
  description = "ID of the inter-Region VPC peering connection."
  value       = module.hybrid_connectivity.vpc_peering_connection_id
}

output "ssm_activation_id" {
  description = "Systems Manager hybrid activation ID. The activation code remains only in sensitive Terraform state."
  value       = module.hybrid_connectivity.ssm_activation_id
  sensitive   = true
}

output "cilium_values" {
  description = "Rendered Cilium Helm values for hybrid nodes. Save this sensitive output to a file before installing Cilium."
  value       = local.cilium_values
  sensitive   = true
}

output "view_remote_bootstrap_log" {
  description = "Command to inspect cloud-init output after connecting through Systems Manager Fleet Manager."
  value       = "sudo tail -n 200 /var/log/cloud-init-output.log"
}

output "lb_controller_role_arn" {
  description = "IAM role ARN bound to the AWS Load Balancer Controller service account through EKS Pod Identity, or null when enable_lb_controller is false."
  value       = module.cluster_region.lb_controller_role_arn
}
