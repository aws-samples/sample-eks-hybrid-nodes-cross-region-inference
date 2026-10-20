variable "name" {
  description = "Name prefix for remote Region connectivity resources."
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster that accepts the hybrid nodes."
  type        = string
}

variable "cluster_region" {
  description = "AWS Region containing the EKS cluster."
  type        = string
}

variable "vpc_cidr" {
  description = "RFC 1918 CIDR for the dedicated remote Region VPC."
  type        = string
}

variable "nat_eip_allocation_id" {
  description = "Allocation ID of the Elastic IP for the remote NAT Gateway. Allocated by the root module so that the cluster can admit this address to the public EKS API endpoint allowlist."
  type        = string
}

variable "cluster_vpc_cidr" {
  description = "CIDR of the EKS cluster VPC."
  type        = string
}

variable "cluster_vpc_id" {
  description = "ID of the EKS cluster VPC."
  type        = string
}

variable "cluster_route_table_ids" {
  description = "Terraform-owned cluster route tables that receive a route to the remote VPC."
  type        = list(string)
}

variable "hybrid_node_role_name" {
  description = "IAM role name used by the Systems Manager hybrid activation."
  type        = string
}

variable "node_subnets" {
  description = "Private remote VPC subnets available to hybrid nodes, keyed by a stable name."
  type = map(object({
    cidr              = string
    availability_zone = optional(string)
  }))

  validation {
    condition     = length(var.node_subnets) > 0
    error_message = "At least one hybrid node subnet is required."
  }
}

variable "egress_subnet" {
  description = "Public subnet that hosts the NAT Gateway for private hybrid-node egress."
  type = object({
    cidr              = string
    availability_zone = optional(string)
  })

  validation {
    condition     = can(cidrnetmask(var.egress_subnet.cidr))
    error_message = "egress_subnet.cidr must be a valid IPv4 CIDR."
  }
}

variable "zone_group_names" {
  description = "Local Zone groups to opt into during apply."
  type        = set(string)
  default     = []
}

variable "ssm_activation_registration_limit" {
  description = "Maximum number of hybrid nodes that may register with the activation."
  type        = number
  default     = 1
}

variable "inference_port" {
  description = "Host-network port exposed by the remote inference sample."
  type        = number
  default     = 8000
}

variable "tags" {
  description = "Tags applied to remote Region connectivity resources."
  type        = map(string)
  default     = {}
}