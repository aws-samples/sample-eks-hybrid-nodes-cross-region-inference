variable "cluster_name" {
  description = "Name of the EKS cluster and related resources."
  type        = string
  default     = "cross-region-inference-demo"

  validation {
    condition     = can(regex("^[0-9A-Za-z][0-9A-Za-z_-]{0,99}$", var.cluster_name))
    error_message = "cluster_name must be 1-100 characters and contain only letters, numbers, hyphens, and underscores."
  }
}

variable "cluster_region" {
  description = "AWS Region that hosts the EKS control plane and core managed nodes."
  type        = string
  default     = "us-west-2"
}

variable "allowed_account_ids" {
  description = "AWS account IDs in which Terraform may operate. Leave empty to disable this provider safeguard."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for account_id in var.allowed_account_ids : can(regex("^[0-9]{12}$", account_id))])
    error_message = "Each allowed account ID must contain exactly 12 digits."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes major.minor version for the EKS control plane."
  type        = string
  default     = "1.37"

  validation {
    condition     = can(regex("^1\\.[0-9]{2}$", var.kubernetes_version))
    error_message = "kubernetes_version must use major.minor format, for example 1.37."
  }
}

variable "cluster_vpc_cidr" {
  description = "RFC 1918 /16 CIDR for the cluster Region VPC."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition = can(cidrnetmask(var.cluster_vpc_cidr)) && endswith(var.cluster_vpc_cidr, "/16") && (
      can(regex("^10\\.", var.cluster_vpc_cidr)) ||
      can(regex("^172\\.(1[6-9]|2[0-9]|3[01])\\.", var.cluster_vpc_cidr)) ||
      can(regex("^192\\.168\\.", var.cluster_vpc_cidr))
    )
    error_message = "cluster_vpc_cidr must be an RFC 1918 /16 CIDR."
  }
}

variable "availability_zone_count" {
  description = "Number of standard Availability Zones used by the cluster VPC."
  type        = number
  default     = 3
}

variable "single_nat_gateway" {
  description = "Use one NAT gateway for all private subnets to reduce demo cost."
  type        = bool
  default     = true
}

variable "endpoint_private_access" {
  description = "Enable the private EKS API endpoint."
  type        = bool
  default     = true
}

# The public EKS API endpoint is always enabled, so it is not a variable.
# Hybrid nodes in the remote Region register through it: EKS publishes the
# private endpoint through a Route 53 private hosted zone associated with the
# cluster VPC alone, so the cluster endpoint does not resolve to its private
# addresses from the remote VPC. Terraform admits the remote NAT Gateway
# address for the nodes; endpoint_public_access_cidrs covers administrators.
variable "endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint, in addition to the remote NAT Gateway address that Terraform admits for hybrid nodes."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for cidr in var.endpoint_public_access_cidrs : can(cidrnetmask(cidr))])
    error_message = "Each public endpoint access entry must be a valid CIDR."
  }

  # Hybrid nodes register with or without this value, so an empty list would
  # produce a working cluster that no administrator can reach with kubectl.
  # Fail the plan instead of surfacing that after a full apply.
  validation {
    condition     = length(var.endpoint_public_access_cidrs) > 0
    error_message = "Set endpoint_public_access_cidrs to the CIDR you reach the API from, for example your own IP as x.x.x.x/32, or 0.0.0.0/0 for a sandbox."
  }
}

variable "enable_cluster_creator_admin_permissions" {
  description = "Grant cluster administrator access to the identity that creates the cluster."
  type        = bool
  default     = true
}

variable "remote_node_cidrs" {
  description = "RFC 1918 CIDRs assigned to remote hybrid nodes."
  type        = list(string)
  default     = ["172.16.0.0/18"]

  validation {
    condition = length(var.remote_node_cidrs) > 0 && alltrue([
      for cidr in var.remote_node_cidrs : can(cidrnetmask(cidr)) && (
        can(regex("^10\\.", cidr)) ||
        can(regex("^172\\.(1[6-9]|2[0-9]|3[01])\\.", cidr)) ||
        can(regex("^192\\.168\\.", cidr))
      )
    ])
    error_message = "remote_node_cidrs must contain valid RFC 1918 CIDRs."
  }

  # The single-entry rule is a validation rather than one of the check blocks
  # below, because locals.tf reduces this list with one(). Variable validation
  # runs before locals are evaluated, so this reports the real problem instead
  # of a bare "Invalid function argument" from one().
  validation {
    condition     = length(var.remote_node_cidrs) == 1
    error_message = "This sample supports exactly one remote node CIDR."
  }
}

variable "remote_pod_cidrs" {
  description = "RFC 1918 overlay CIDRs assigned to hybrid-node pods. They must not overlap either VPC or the node CIDRs."
  type        = list(string)
  default     = ["10.100.0.0/16"]

  validation {
    condition = length(var.remote_pod_cidrs) > 0 && alltrue([
      for cidr in var.remote_pod_cidrs : can(cidrnetmask(cidr)) && (
        can(regex("^10\\.", cidr)) ||
        can(regex("^172\\.(1[6-9]|2[0-9]|3[01])\\.", cidr)) ||
        can(regex("^192\\.168\\.", cidr))
      )
    ])
    error_message = "remote_pod_cidrs must contain valid RFC 1918 CIDRs."
  }

  # Kept here for the same reason as the remote_node_cidrs single-entry rule:
  # locals.tf and the Cilium pod pool guard both reduce this list with one().
  validation {
    condition     = length(var.remote_pod_cidrs) == 1
    error_message = "This sample supports exactly one Cilium remote pod CIDR."
  }
}

variable "cilium_pod_cidr_mask_size" {
  description = "Per-node Cilium pod CIDR prefix allocated from remote_pod_cidrs."
  type        = number
  default     = 25

  validation {
    condition     = var.cilium_pod_cidr_mask_size >= 24 && var.cilium_pod_cidr_mask_size <= 30
    error_message = "cilium_pod_cidr_mask_size must be between 24 and 30."
  }
}

variable "core_node_instance_types" {
  description = "EC2 instance types used by the managed node group for core services."
  type        = list(string)
  default     = ["m6i.large"]

  validation {
    condition     = length(var.core_node_instance_types) > 0
    error_message = "At least one core node instance type is required."
  }
}

variable "core_node_min_size" {
  description = "Minimum size of the core managed node group."
  type        = number
  default     = 1
}

variable "core_node_desired_size" {
  description = "Desired size of the core managed node group."
  type        = number
  default     = 1
}

variable "core_node_max_size" {
  description = "Maximum size of the core managed node group."
  type        = number
  default     = 3
}

variable "enable_lb_controller" {
  description = "Create the IAM role and Pod Identity association for the AWS Load Balancer Controller used by the optional LiteLLM gateway."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags applied to all resources."
  type        = map(string)
  default     = {}
}

check "core_node_group_sizes" {
  assert {
    condition = (
      var.core_node_min_size >= 0 &&
      var.core_node_min_size <= var.core_node_desired_size &&
      var.core_node_desired_size <= var.core_node_max_size
    )
    error_message = "Core node sizes must satisfy min_size <= desired_size <= max_size."
  }
}

variable "remote_region" {
  description = "AWS Region that hosts the experimental remote hybrid node capacity."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = var.remote_region != var.cluster_region
    error_message = "remote_region must differ from cluster_region for this cross-Region sample."
  }
}

variable "remote_node_subnets" {
  description = "Private subnets carved from remote_node_cidrs for hybrid nodes, keyed by a stable name."
  type = map(object({
    cidr              = string
    availability_zone = optional(string)
  }))
  default = {
    default = {
      cidr = "172.16.0.0/24"
    }
  }

  validation {
    condition = length(var.remote_node_subnets) > 0 && alltrue([
      for subnet in values(var.remote_node_subnets) : can(cidrnetmask(subnet.cidr))
    ])
    error_message = "remote_node_subnets must contain at least one valid IPv4 CIDR."
  }
}

variable "remote_egress_subnet" {
  description = "Public subnet in the remote VPC that hosts the NAT Gateway for private hybrid-node egress."
  type = object({
    cidr              = string
    availability_zone = optional(string)
  })
  default = {
    cidr = "172.16.255.0/24"
  }

  validation {
    condition     = can(cidrnetmask(var.remote_egress_subnet.cidr))
    error_message = "remote_egress_subnet.cidr must be a valid IPv4 CIDR."
  }
}

variable "remote_zone_group_names" {
  description = "Local Zone groups to opt into during apply, for example us-east-1-atl-2."
  type        = set(string)
  default     = []
}

variable "hybrid_nodes" {
  description = "Hybrid EC2 nodes to launch in the dedicated remote VPC."
  type = map(object({
    subnet_key                    = string
    instance_type                 = string
    ami_id                        = optional(string)
    root_volume_size              = optional(number, 100)
    node_labels                   = optional(map(string), {})
    node_taints                   = optional(list(string), [])
    capacity_block_reservation_id = optional(string)
  }))
  default = {
    inference_gpu = {
      subnet_key    = "default"
      instance_type = "g5.2xlarge"
      ami_id        = "ami-replace-with-gpu-ready-image"
      node_taints   = ["nvidia.com/gpu=true:NoSchedule"]
    }
  }

  validation {
    condition = alltrue([
      for node in values(var.hybrid_nodes) : contains(keys(var.remote_node_subnets), node.subnet_key)
    ])
    error_message = "Each hybrid node subnet_key must identify an entry in remote_node_subnets."
  }

  validation {
    condition = alltrue([
      for node in values(var.hybrid_nodes) : node.capacity_block_reservation_id == null || can(regex("^cr-[0-9a-f]+$", node.capacity_block_reservation_id))
    ])
    error_message = "Each capacity_block_reservation_id must be null or begin with cr-."
  }

  # The default above is the deliberately unusable "ami-replace-with-gpu-ready-image"
  # marker, because no GPU AMI with NVIDIA drivers and the container toolkit is
  # publishable as a sample default. Left unreplaced it reaches EC2 and comes
  # back as InvalidAMIID.Malformed, long after the VPCs, peering, and cluster
  # have already been created. Checking the shape here turns that into a plan
  # failure. Omitting ami_id entirely stays valid: the hybrid-node module then
  # resolves the latest AL2023 image through SSM, which is enough for a
  # CPU-only node.
  validation {
    condition = alltrue([
      for node in values(var.hybrid_nodes) : node.ami_id == null || can(regex("^ami-[0-9a-f]{8,17}$", node.ami_id))
    ])
    error_message = "Each hybrid_nodes ami_id must be a real AMI ID such as ami-0123456789abcdef0, or omitted to resolve the latest AL2023 image through SSM. Replace the ami-replace-with-gpu-ready-image placeholder with a GPU AMI that carries NVIDIA drivers and the NVIDIA container toolkit for containerd, available in the Availability Zone of the node's subnet."
  }
}

variable "nodeadm_version" {
  description = "nodeadm release installed on Hybrid Nodes, checked against the nodeadm.sha256 published with it."
  type        = string
  default     = "v1.0.20"
}

variable "ssm_activation_registration_limit" {
  description = "Maximum nodes that can register with the Systems Manager hybrid activation."
  type        = number
  default     = 5

  validation {
    condition = (
      var.ssm_activation_registration_limit >= length(var.hybrid_nodes) &&
      var.ssm_activation_registration_limit <= 1000
    )
    error_message = "ssm_activation_registration_limit must cover all configured hybrid_nodes and cannot exceed 1000."
  }
}

variable "remote_vpc_cidr" {
  description = "RFC 1918 /16 CIDR for the experimental remote Region VPC."
  type        = string
  default     = "172.16.0.0/16"

  validation {
    condition = can(cidrnetmask(var.remote_vpc_cidr)) && endswith(var.remote_vpc_cidr, "/16") && (
      can(regex("^10\\.", var.remote_vpc_cidr)) ||
      can(regex("^172\\.(1[6-9]|2[0-9]|3[01])\\.", var.remote_vpc_cidr)) ||
      can(regex("^192\\.168\\.", var.remote_vpc_cidr))
    )
    error_message = "remote_vpc_cidr must be an RFC 1918 /16 CIDR."
  }
}

check "cilium_pod_pool_size" {
  assert {
    condition     = var.cilium_pod_cidr_mask_size >= tonumber(split("/", one(var.remote_pod_cidrs))[1])
    error_message = "cilium_pod_cidr_mask_size must be equal to or more specific than the remote pod CIDR prefix."
  }
}

check "cidr_layout" {
  assert {
    condition = length(local.overlapping_cidr_pairs) == 0
    error_message = format(
      "These CIDRs must not overlap: %s. The cluster VPC, remote node, and Cilium pod networks must be distinct, hybrid-node subnets must not overlap each other, and the NAT egress subnet must sit outside the node network.",
      join(", ", [for pair in local.overlapping_cidr_pairs : "${pair[0]} and ${pair[1]}"])
    )
  }

  assert {
    condition = length(local.unnested_cidr_pairs) == 0
    error_message = format(
      "These CIDRs must be contained within the first of each pair: %s. Remote node and egress subnets are carved out of remote_vpc_cidr, and each remote_node_subnets entry out of remote_node_cidrs.",
      join(", ", [for pair in local.unnested_cidr_pairs : "${pair[1]} within ${pair[0]}"])
    )
  }
}
