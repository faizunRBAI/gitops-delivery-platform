# ACM certificate for the Argo CD admin UI.
#
# The DNS for royalbengal.xyz is hosted in cPanel, NOT Route 53, so terraform
# cannot create the validation record. That single fact drives the shape of
# this file and is worth stating plainly, because the obvious "complete"
# version of it is a trap:
#
#   There is deliberately NO `aws_acm_certificate_validation` resource here.
#
# That resource blocks the apply until ACM reports ISSUED, waiting up to 72
# hours for a DNS record that nothing in this pipeline is able to write. It
# would hang the provision stage until the 45-minute job timeout, every run,
# and burn a recovery attempt each time. Requesting the certificate without
# waiting on it completes in seconds and leaves the cert in
# PENDING_VALIDATION, which is a perfectly good state to be in: the outputs
# below publish the CNAME the operator must add by hand, and the configure
# stage reads the certificate's status to decide whether the Argo CD ingress
# can be created yet.
#
# Once the operator adds the CNAME in cPanel, ACM issues the certificate on
# its own schedule (typically 5-30 minutes) with no further terraform action.
# The next deploy sees status=ISSUED and attaches the listener.

resource "aws_acm_certificate" "argocd" {
  domain_name       = var.argocd_hostname
  validation_method = "DNS"

  # The certificate is referenced by an ALB listener managed outside
  # terraform (the AWS Load Balancer Controller reads the ARN from an Ingress
  # annotation). Replacing a certificate that a listener still references
  # fails, so build the replacement before destroying the old one.
  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name      = "${var.project_name}-argocd"
    Project   = var.project_name
    ManagedBy = "udap"
  }
}
