# These five outputs are the ONLY channel by which later stages learn about the
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
