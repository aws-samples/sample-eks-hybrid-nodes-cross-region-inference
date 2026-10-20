module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = var.cluster_name
  cidr = var.vpc_cidr
  azs  = local.availability_zones

  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets
  intra_subnets   = local.control_plane_subnets

  enable_nat_gateway = true
  single_nat_gateway = var.single_nat_gateway

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = var.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  endpoint_private_access = var.endpoint_private_access

  # The public endpoint is always enabled, because hybrid nodes register through
  # it rather than over peering. EKS publishes the private endpoint through a
  # Route 53 private hosted zone associated with the cluster VPC alone, and
  # nothing associates or forwards that zone into the remote VPC, so nodeadm,
  # kubelet, and Cilium all resolve the cluster endpoint to its public addresses
  # and egress through the remote NAT Gateway. Admitting that one address keeps
  # registration working while endpoint_public_access_cidrs carries nothing but
  # the administrator CIDR, and the allowlist is never empty, so EKS cannot fall
  # back to opening the endpoint to 0.0.0.0/0.
  endpoint_public_access = true
  endpoint_public_access_cidrs = concat(
    var.endpoint_public_access_cidrs,
    ["${var.remote_nat_public_ip}/32"],
  )

  # This sample grants access only through access entries, so "API" alone would
  # cover it. Both modes stay enabled so that you can adapt the cluster without
  # recreating it: EKS allows API_AND_CONFIG_MAP to API but not the reverse, and
  # switching drops any aws-auth entries added by hand.
  authentication_mode                      = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = var.enable_cluster_creator_admin_permissions


  addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      before_compute = true

      # Excluding the remote networks from source NAT lets cluster-Region pods
      # reach the remote Region over VPC peering.
      #
      # By default vpc-cni source-NATs pod traffic leaving the VPC to the node's
      # primary ENI address, while separately binding each pod to a specific ENI
      # through policy routing. A pod placed on a secondary ENI therefore egresses
      # that ENI carrying an address belonging to the primary one, and EC2
      # source/destination checking silently drops the packet.
      #
      # vpc-cni selects its routing mark from the pre-DNAT destination, so a
      # ClusterIP that kube-proxy rewrites to an out-of-VPC endpoint defeats the
      # mechanism. Reaching the remote-vllm Service then succeeds or times out
      # purely according to which ENI the calling pod landed on, while a direct
      # call to the Hybrid Node IP keeps working and masks the cause.
      #
      # With these destinations excluded, pods keep their own source address,
      # which is assigned to the ENI they leave through, so the check passes. The
      # remote security group already admits the cluster VPC CIDR and the remote
      # route table already returns it over the peering connection.
      #
      # This is scoped to the remote networks rather than set through
      # AWS_VPC_K8S_CNI_EXTERNALSNAT, which would disable source NAT for every
      # destination outside the VPC, including internet-bound traffic. Keeping
      # the source address also preserves it for NetworkPolicy, flow logs, and
      # applications that inspect the caller. The remote pod CIDRs are listed for
      # when they are made routable with BGP or the EKS Hybrid Nodes gateway;
      # until then they are unreachable either way.
      configuration_values = jsonencode({
        env = {
          AWS_VPC_K8S_CNI_EXCLUDE_SNAT_CIDRS = join(",", var.snat_exclude_cidrs)
        }
      })
    }
    eks-pod-identity-agent = {
      before_compute = true
    }
  }

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  # This rule governs the private endpoint, which hybrid nodes do not currently
  # use, because the cluster endpoint does not resolve to its private addresses
  # from the remote VPC. It is kept because the remote node CIDR is routed over
  # peering, so adding Route 53 Resolver forwarding moves node API traffic onto
  # the private endpoint without a security group change.
  #
  # There is deliberately no equivalent rule for remote_pod_cidrs. Cilium
  # allocates pod addresses from an overlay pool that no route table carries, so
  # no packet can reach the cluster VPC with a pod source address and such a
  # rule could never match. Making pods routable needs Cilium BGP or the EKS
  # Hybrid Nodes gateway, and the rules to go with it.
  security_group_additional_rules = {
    hybrid_nodes_https = {
      description = "Remote hybrid nodes to EKS API"
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      type        = "ingress"
      cidr_blocks = var.remote_node_cidrs
    }
  }

  access_entries = {
    hybrid_node_role = {
      principal_arn = module.hybrid_node_role.arn
      type          = "HYBRID_LINUX"
    }
  }

  remote_network_config = {
    remote_node_networks = {
      cidrs = var.remote_node_cidrs
    }
    remote_pod_networks = {
      cidrs = var.remote_pod_cidrs
    }
  }

  eks_managed_node_groups = {
    core = {
      name           = "core"
      description    = "Managed nodes for cluster services"
      iam_role_name  = "${var.cluster_name}-core"
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.core_node_instance_types
      subnet_ids     = module.vpc.private_subnets

      min_size     = var.core_node_min_size
      desired_size = var.core_node_desired_size
      max_size     = var.core_node_max_size

      node_repair_config = {
        enabled = true
      }

      block_device_mappings = {
        root = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 20
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      labels = {
        "node-role" = "core"
      }
    }
  }

  tags = var.tags
}

module "hybrid_node_role" {
  source  = "terraform-aws-modules/eks/aws//modules/hybrid-node-role"
  version = "21.29.0"

  name            = "${var.cluster_name}-hybrid-node"
  use_name_prefix = false
  policy_name     = "${var.cluster_name}-hybrid-node"
  cluster_arns    = [local.cluster_arn]

  tags = var.tags
}

# IAM for the AWS Load Balancer Controller used by the optional gateway. EKS Pod
# Identity binds the role to the controller's service account, so no OIDC trust
# policy is needed and terraform destroy removes it with the cluster.
module "lb_controller_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.9.0"
  count   = var.enable_lb_controller ? 1 : 0

  name            = "${var.cluster_name}-lbc"
  use_name_prefix = false

  attach_aws_lb_controller_policy = true
  # The module's default policy name is fixed, so a second deployment in the
  # same account would collide with it.
  aws_lb_controller_policy_name = "${var.cluster_name}-lbc"

  associations = {
    controller = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }

  tags = var.tags
}
