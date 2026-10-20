provider "aws" {
  alias               = "cluster"
  region              = var.cluster_region
  allowed_account_ids = length(var.allowed_account_ids) > 0 ? var.allowed_account_ids : null

  default_tags {
    tags = local.tags
  }
}

provider "aws" {
  alias               = "remote"
  region              = var.remote_region
  allowed_account_ids = length(var.allowed_account_ids) > 0 ? var.allowed_account_ids : null

  default_tags {
    tags = local.tags
  }
}
