variable "project_name" {
  description = "Branch-scoped project name. Supplied as TF_VAR_project_name from the provision stage env (platform PROJECT_NAME secret). Drives resource naming and the Project tag."
  type        = string
}

variable "aws_region" {
  description = "AWS region for all resources. Supplied as TF_VAR_aws_region from the provision stage env."
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes minor version for the EKS control plane. Must be in EKS STANDARD support (1.30-1.32 are extended support only and bill at a premium)."
  type        = string
  default     = "1.33"
}

variable "cluster_public_access_cidrs" {
  description = "CIDRs allowed to reach the EKS public API endpoint. The GitHub-hosted CI runner has no fixed egress IP, so Phase 1 must allow 0.0.0.0/0 for the configure stage to run helm/kubectl at all. Narrow this to your runner's egress range (or move to a self-hosted runner inside the VPC and disable public access) as a Phase 2 hardening step. Authentication is IAM in API mode regardless — this controls network reachability, not authorization."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "vpc_cidr" {
  description = "CIDR block for the dedicated VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "node_instance_type" {
  description = "EC2 instance type for the managed node group."
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  description = "Desired number of worker nodes."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of worker nodes."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of worker nodes."
  type        = number
  default     = 4
}
