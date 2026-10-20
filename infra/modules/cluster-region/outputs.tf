output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = module.eks.cluster_name
}

output "cluster_arn" {
  description = "ARN of the EKS cluster."
  value       = module.eks.cluster_arn
}

output "cluster_endpoint" {
  description = "Endpoint for the EKS Kubernetes API server."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded certificate data for the cluster."
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "vpc_id" {
  description = "ID of the cluster Region VPC."
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "CIDR of the cluster Region VPC."
  value       = module.vpc.vpc_cidr_block
}

output "private_route_table_ids" {
  description = "Route tables associated with managed-node private subnets."
  value       = module.vpc.private_route_table_ids
}

output "intra_route_table_ids" {
  description = "Route tables associated with EKS control-plane subnets."
  value       = module.vpc.intra_route_table_ids
}

output "hybrid_node_role_arn" {
  description = "IAM role ARN used to authenticate remote hybrid nodes."
  value       = module.hybrid_node_role.arn
}

output "hybrid_node_role_name" {
  description = "IAM role name used by the Systems Manager hybrid activation."
  value       = module.hybrid_node_role.name
}

output "lb_controller_role_arn" {
  description = "IAM role ARN bound to the AWS Load Balancer Controller service account, or null when disabled."
  value       = try(module.lb_controller_pod_identity[0].iam_role_arn, null)
}
