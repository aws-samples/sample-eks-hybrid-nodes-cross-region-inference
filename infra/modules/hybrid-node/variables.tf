variable "name" {
  description = "Name assigned to the hybrid node."
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster that accepts the hybrid node."
  type        = string
}

variable "cluster_region" {
  description = "AWS Region containing the EKS cluster and Systems Manager activation."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes major.minor version installed by nodeadm."
  type        = string
}

variable "subnet_id" {
  description = "Remote VPC subnet in which to launch the hybrid node."
  type        = string
}

variable "security_group_ids" {
  description = "Security groups attached to the hybrid node."
  type        = list(string)
}

variable "instance_type" {
  description = "EC2 instance type for the hybrid node."
  type        = string
}

variable "ami_id" {
  description = "Optional AMI ID. Null selects the current AL2023 x86_64 AMI from Parameter Store."
  type        = string
  default     = null
}

variable "root_volume_size" {
  description = "Size in GiB of the encrypted root volume."
  type        = number
  default     = 100

  validation {
    condition     = var.root_volume_size >= 20
    error_message = "root_volume_size must be at least 20 GiB."
  }
}

variable "nodeadm_version" {
  description = "nodeadm release downloaded from hybrid-assets.eks.amazonaws.com, for example v1.0.20."
  type        = string

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.nodeadm_version))
    error_message = "nodeadm_version must look like v1.0.20."
  }
}

variable "ssm_activation_id" {
  description = "Systems Manager hybrid activation ID created in the cluster Region."
  type        = string
  sensitive   = true
}

variable "ssm_activation_code" {
  description = "Short-lived Systems Manager hybrid activation code."
  type        = string
  sensitive   = true
}

variable "node_labels" {
  description = "Additional Kubernetes labels registered by kubelet."
  type        = map(string)
  default     = {}
}

variable "node_taints" {
  description = "Additional kubelet taints in key=value:Effect form."
  type        = list(string)
  default     = []
}

variable "capacity_block_reservation_id" {
  description = "Optional EC2 Capacity Block reservation ID. Setting it enables the capacity-block market type."
  type        = string
  default     = null

  validation {
    condition     = var.capacity_block_reservation_id == null || can(regex("^cr-[0-9a-f]+$", var.capacity_block_reservation_id))
    error_message = "capacity_block_reservation_id must be null or a Capacity Reservation ID beginning with cr-."
  }
}

variable "tags" {
  description = "Tags applied to the hybrid node and root volume."
  type        = map(string)
  default     = {}
}