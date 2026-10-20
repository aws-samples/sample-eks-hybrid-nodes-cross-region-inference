locals {
  network_cidrs = concat(
    [var.cluster_vpc_cidr],
    var.remote_node_cidrs,
    var.remote_pod_cidrs
  )

  remote_node_cidr   = one(var.remote_node_cidrs)
  remote_pod_cidr    = one(var.remote_pod_cidrs)
  node_subnet_cidrs  = [for subnet in values(var.remote_node_subnets) : subnet.cidr]
  egress_subnet_cidr = var.remote_egress_subnet.cidr

  # Two CIDR blocks are either nested or disjoint; they never partially overlap.
  # So "do these overlap" reduces to "does either one's first address fall inside
  # the other", and containment needs no address arithmetic: re-mask the inner
  # block's base address with the outer block's prefix length, and it equals the
  # outer block's base address only when it lies inside it.
  #
  # Each entry below is a pair of CIDRs that must not overlap. Collecting the
  # offending pairs rather than reducing to a boolean lets the check block in
  # variables.tf name the CIDRs that actually clash.
  disjoint_cidr_pairs = concat(
    # The cluster VPC, remote node, and remote pod networks must all be distinct.
    [
      for pair in setproduct(range(length(local.network_cidrs)), range(length(local.network_cidrs))) :
      [local.network_cidrs[pair[0]], local.network_cidrs[pair[1]]]
      if pair[0] < pair[1]
    ],
    # No two hybrid-node subnets may overlap.
    [
      for pair in setproduct(range(length(local.node_subnet_cidrs)), range(length(local.node_subnet_cidrs))) :
      [local.node_subnet_cidrs[pair[0]], local.node_subnet_cidrs[pair[1]]]
      if pair[0] < pair[1]
    ],
    # The Cilium overlay pool stays outside both VPCs in full, not just outside
    # the node CIDR carved from the remote one.
    [[var.remote_vpc_cidr, local.remote_pod_cidr]],
    [[var.cluster_vpc_cidr, local.remote_pod_cidr]],
    # The NAT egress subnet sits outside the node network and every node subnet.
    [[local.egress_subnet_cidr, local.remote_node_cidr]],
    [for cidr in local.node_subnet_cidrs : [local.egress_subnet_cidr, cidr]],
  )

  overlapping_cidr_pairs = [
    for pair in local.disjoint_cidr_pairs : pair
    if cidrhost(pair[0], 0) == cidrhost("${cidrhost(pair[1], 0)}/${split("/", pair[0])[1]}", 0) ||
    cidrhost(pair[1], 0) == cidrhost("${cidrhost(pair[0], 0)}/${split("/", pair[1])[1]}", 0)
  ]

  # Containment is the same test in one direction only: outer must hold inner's
  # base address. Each entry is [outer, inner].
  nested_cidr_pairs = concat(
    # Remote node and egress networks are carved out of the remote VPC.
    [[var.remote_vpc_cidr, local.remote_node_cidr]],
    [[var.remote_vpc_cidr, local.egress_subnet_cidr]],
    # Every hybrid-node subnet comes from the remote node network.
    [for cidr in local.node_subnet_cidrs : [local.remote_node_cidr, cidr]],
  )

  unnested_cidr_pairs = [
    for pair in local.nested_cidr_pairs : pair
    if cidrhost(pair[0], 0) != cidrhost("${cidrhost(pair[1], 0)}/${split("/", pair[0])[1]}", 0)
  ]

  cilium_values = templatefile("${path.module}/templates/cilium-values.yaml.tftpl", {
    cluster_endpoint_host = trimsuffix(trimprefix(module.cluster_region.cluster_endpoint, "https://"), "/")
    remote_pod_cidr       = local.remote_pod_cidr
    pod_cidr_mask_size    = var.cilium_pod_cidr_mask_size
  })

  tags = merge(
    {
      Project   = var.cluster_name
      ManagedBy = "Terraform"
      Sample    = "eks-hybrid-nodes-cross-region-inference"
    },
    var.tags
  )
}
