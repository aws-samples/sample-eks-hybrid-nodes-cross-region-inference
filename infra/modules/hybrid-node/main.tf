data "aws_ssm_parameter" "al2023" {
  count = var.ami_id == null ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  ami_id = coalesce(var.ami_id, try(data.aws_ssm_parameter.al2023[0].value, null))

  # Both flags take one comma-separated list. Repeating --register-with-taints
  # does not accumulate: kubelet parses each occurrence and assigns the result,
  # so a second flag silently discards the taints from the first.
  kubelet_flags = concat(
    length(var.node_labels) == 0 ? [] : ["--node-labels=${join(",", [for key, value in var.node_labels : "${key}=${value}"])}"],
    length(var.node_taints) == 0 ? [] : ["--register-with-taints=${join(",", var.node_taints)}"]
  )

  node_config = <<-YAML
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      cluster:
        name: ${var.cluster_name}
        region: ${var.cluster_region}
      kubelet:
        flags: ${jsonencode(local.kubelet_flags)}
      hybrid:
        ssm:
          activationCode: ${var.ssm_activation_code}
          activationId: ${var.ssm_activation_id}
  YAML
}

resource "aws_instance" "this" {
  ami                         = local.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = var.security_group_ids
  associate_public_ip_address = false
  source_dest_check           = true
  ebs_optimized               = true

  user_data_replace_on_change = true
  user_data                   = <<-CLOUD_CONFIG
    #cloud-config
    package_update: true
    packages:
      - curl

    write_files:
      - path: /opt/eks/nodeConfig.yaml
        owner: root:root
        permissions: '0600'
        encoding: b64
        content: ${base64encode(local.node_config)}

    runcmd:
      - [sh, -c, "cd /tmp && curl --fail --location --remote-name https://hybrid-assets.eks.amazonaws.com/releases/${var.nodeadm_version}/bin/linux/amd64/nodeadm --remote-name https://hybrid-assets.eks.amazonaws.com/releases/${var.nodeadm_version}/bin/linux/amd64/nodeadm.sha256 && sha256sum --check --strict nodeadm.sha256 && install -m 0755 nodeadm /usr/local/bin/nodeadm"]
      - [/usr/local/bin/nodeadm, install, "${var.kubernetes_version}", --credential-provider, ssm]
      - [/usr/local/bin/nodeadm, init, --config-source, file:///opt/eks/nodeConfig.yaml]
      - [sh, -c, "if command -v nvidia-ctk >/dev/null 2>&1; then nvidia-ctk runtime configure --runtime=containerd --set-as-default && systemctl restart containerd; fi"]
      - [sh, -c, "shred --remove /opt/eks/nodeConfig.yaml || rm -f /opt/eks/nodeConfig.yaml"]
  CLOUD_CONFIG

  dynamic "instance_market_options" {
    for_each = var.capacity_block_reservation_id == null ? [] : [1]
    content {
      market_type = "capacity-block"
    }
  }

  dynamic "capacity_reservation_specification" {
    for_each = var.capacity_block_reservation_id == null ? [] : [var.capacity_block_reservation_id]
    content {
      capacity_reservation_target {
        capacity_reservation_id = capacity_reservation_specification.value
      }
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted             = true
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
  }

  volume_tags = var.tags
  tags        = merge(var.tags, { Name = var.name })
}