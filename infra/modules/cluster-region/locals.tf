data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  availability_zones = slice(
    data.aws_availability_zones.available.names,
    0,
    min(var.availability_zone_count, length(data.aws_availability_zones.available.names))
  )
  cluster_arn = "arn:${data.aws_partition.current.partition}:eks:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"

  private_subnets = [
    for index, _ in local.availability_zones : cidrsubnet(var.vpc_cidr, 4, index)
  ]
  public_subnets = [
    for index, _ in local.availability_zones : cidrsubnet(var.vpc_cidr, 8, index + 48)
  ]
  control_plane_subnets = [
    for index, _ in local.availability_zones : cidrsubnet(var.vpc_cidr, 8, index + 52)
  ]
}
