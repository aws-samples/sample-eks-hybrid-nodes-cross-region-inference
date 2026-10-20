variable "cluster_name" {
  description = "Name of the EKS cluster and its VPC."
  type        = string

  validation {
    condition     = can(regex("^[0-9A-Za-z][0-9A-Za-z_-]{0,99}$", var.cluster_name))
    error_message = "cluster_name must be 1-100 characters and contain only letters, numbers, hyphens, and underscores."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes major.minor version for the EKS control plane."
  type        = string

  validation {
    condition     = can(regex("^1\\.[0-9]{2}$", var.kubernetes_version))
    error_message = "kubernetes_version must use major.minor format, for example 1.37."
  }
}

variable "vpc_cidr" {
  description = "RFC 1918 /16 CIDR for the cluster Region VPC."
  type        = string

  validation {
    condition = can(cidrnetmask(var.vpc_cidr)) && endswith(var.vpc_cidr, "/16") && (
      can(regex("^10\\.", var.vpc_cidr)) ||
      can(regex("^172\\.(1[6-9]|2[0-9]|3[01])\\.", var.vpc_cidr)) ||
      can(regex("^192\\.168\\.", var.vpc_cidr))
    )
    error_message = "vpc_cidr must be an RFC 1918 /16 CIDR."
  }
}

variable "availability_zone_count" {
  description = "Number of standard Availability Zones used by the VPC."
  type        = number
  default     = 3

  validation {
    condition     = var.availability_zone_count >= 2 && var.availability_zone_count <= 3
    error_message = "availability_zone_count must be between 2 and 3."
  }
}

variable "single_nat_gateway" {
  description = "Use one NAT gateway for all private subnets to reduce demo cost."
  type        = bool
  default     = true
}

variable "endpoint_private_access" {
  description = "Enable the private EKS API endpoint."
  type        = bool
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint."
  type        = list(string)
}

variable "remote_nat_public_ip" {
  description = "Public address of the remote NAT Gateway, admitted to the public EKS API endpoint so that hybrid nodes can register."
  type        = string
}

variable "enable_cluster_creator_admin_permissions" {
  description = "Grant cluster administrator access to the identity that creates the cluster."
  type        = bool
}

variable "remote_node_cidrs" {
  description = "RFC 1918 CIDRs assigned to remote hybrid nodes."
  type        = list(string)
}

variable "remote_pod_cidrs" {
  description = "RFC 1918 CIDRs assigned to pods on remote hybrid nodes."
  type        = list(string)
}

variable "snat_exclude_cidrs" {
  description = "Destinations vpc-cni must not source-NAT, so cluster-Region pods keep their own address when reaching the remote Region over peering."
  type        = list(string)

  validation {
    condition = length(var.snat_exclude_cidrs) > 0 && alltrue([
      for cidr in var.snat_exclude_cidrs : can(cidrnetmask(cidr))
    ])
    error_message = "snat_exclude_cidrs must contain at least one valid IPv4 CIDR."
  }
}

variable "core_node_instance_types" {
  description = "EC2 instance types used by the managed node group for core services."
  type        = list(string)
}

variable "core_node_min_size" {
  description = "Minimum size of the core managed node group."
  type        = number
}

variable "core_node_desired_size" {
  description = "Desired size of the core managed node group."
  type        = number
}

variable "core_node_max_size" {
  description = "Maximum size of the core managed node group."
  type        = number
}

variable "enable_lb_controller" {
  description = "Create the Pod Identity IAM role for the AWS Load Balancer Controller."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to resources in the cluster Region."
  type        = map(string)
  default     = {}
}
