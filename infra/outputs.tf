# These outputs are the ONLY channel by which later stages learn about the
# infrastructure. configure and verify re-run `terraform init` with identical
# -backend-config flags and read them with `terraform output -raw` — never via
# job outputs, which GitHub silently drops when the value contains a secret
# substring (PROJECT_NAME is a secret, and every name below embeds it).

output "cluster_name" {
  description = "EKS cluster name (project name truncated to 24 chars + -eks)."
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = aws_eks_cluster.main.endpoint
}

output "ecr_repository_url" {
  description = "ECR repository URL the app image is pushed to and pulled from."
  value       = aws_ecr_repository.app.repository_url
}

output "alb_controller_role_arn" {
  description = "IRSA role ARN for the AWS Load Balancer Controller service account."
  value       = aws_iam_role.alb_controller.arn
}

output "vpc_id" {
  description = "VPC id, required by the AWS Load Balancer Controller helm values."
  value       = aws_vpc.main.id
}

# --- Argo CD UI exposure -----------------------------------------------------
#
# The certificate is requested but NOT waited on (see acm.tf). These four
# outputs let the configure stage decide what it is allowed to do on this run,
# and let it print the validation record for the operator to add in cPanel.

output "argocd_hostname" {
  description = "Hostname the Argo CD UI is served on."
  value       = var.argocd_hostname
}

output "acm_certificate_arn" {
  description = "ARN of the Argo CD ACM certificate. Referenced by the ingress certificate-arn annotation once the certificate is ISSUED."
  value       = aws_acm_certificate.argocd.arn
}

output "acm_certificate_status" {
  description = "ACM validation status: PENDING_VALIDATION until the operator adds the CNAME in cPanel, then ISSUED. The configure stage reads this to decide whether the Argo CD ingress can be created — attaching an unissued certificate to an ALB listener fails."
  value       = aws_acm_certificate.argocd.status
}

output "acm_validation_name" {
  description = "Name of the DNS CNAME record ACM requires for validation. Fully qualified; cPanel's Zone Editor usually appends the zone automatically, so the operator normally enters this with the zone suffix stripped."
  value       = one(aws_acm_certificate.argocd.domain_validation_options).resource_record_name
}

output "acm_validation_value" {
  description = "Value of the DNS CNAME record ACM requires for validation. Entered verbatim in cPanel."
  value       = one(aws_acm_certificate.argocd.domain_validation_options).resource_record_value
}
