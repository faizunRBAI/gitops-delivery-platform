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

# NOTE: argocd_allowed_cidrs below is a DIFFERENT exposure from
# cluster_public_access_cidrs above and must not be confused with it. That one
# governs the EKS API endpoint (IAM-authenticated, accepted exception
# AVD-AWS-0040/0041). This one governs the Argo CD web UI, which authenticates
# with a PASSWORD — a single factor in front of cluster-admin authority. It has
# no default on purpose.
variable "argocd_allowed_cidrs" {
  description = "Source CIDRs permitted to reach the Argo CD UI load balancer. Written into the ALB security group via the ingress inbound-cidrs annotation. Supplied as TF_VAR_argocd_allowed_cidrs from the ARGOCD_ALLOWED_CIDRS pipeline secret so the operator's home IP is not published in this public repository. INTENTIONALLY HAS NO DEFAULT: a missing value must fail the apply loudly rather than quietly defaulting to an open endpoint. Do not add a default, and do not set this to 0.0.0.0/0 — the Argo CD UI can change what runs in the cluster and read every Secret Argo manages. If access is needed from unpredictable networks, the correct change is SSO/OIDC with admin.enabled=false, not a wider CIDR."
  type        = list(string)

  validation {
    condition     = !contains(var.argocd_allowed_cidrs, "0.0.0.0/0")
    error_message = "argocd_allowed_cidrs must not contain 0.0.0.0/0. The Argo CD UI holds cluster-admin authority behind a single password; exposing it to the internet is not a supported configuration. Use a specific CIDR, or switch to SSO/OIDC with admin.enabled=false."
  }

  validation {
    condition     = length(var.argocd_allowed_cidrs) > 0
    error_message = "argocd_allowed_cidrs must contain at least one CIDR."
  }
}

variable "argocd_hostname" {
  description = "Fully-qualified hostname for the Argo CD UI. An ACM certificate is requested for this name; DNS for the zone is hosted in cPanel, so the validation CNAME and the final ALB CNAME are added manually by the operator."
  type        = string
  default     = "argocd.rbai.royalbengal.xyz"
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
