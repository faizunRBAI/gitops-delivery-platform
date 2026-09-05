terraform {
  required_version = ">= 1.9.0"

  # Backend configuration is intentionally EMPTY.
  # bucket / key / region are supplied by the provision stage via -backend-config
  # flags (platform TF_STATE_BUCKET + PROJECT_NAME secrets). Backend blocks cannot
  # reference variables, and hardcoding a key would share state across branches.
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # Every taggable resource in this root inherits these tags. UDAP resource
  # discovery, the architecture report and the Operations Console locate this
  # project's infrastructure by Project=<project_name>.
  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "udap"
    }
  }
}
