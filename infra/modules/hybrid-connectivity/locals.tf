data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }
}

locals {
  egress_subnet_availability_zone = coalesce(
    var.egress_subnet.availability_zone,
    data.aws_availability_zones.available.names[0]
  )

  node_subnets = {
    for name, subnet in var.node_subnets : name => {
      cidr              = subnet.cidr
      availability_zone = coalesce(subnet.availability_zone, data.aws_availability_zones.available.names[0])
    }
  }
}