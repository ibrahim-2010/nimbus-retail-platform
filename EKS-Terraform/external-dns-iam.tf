# ──────────────────────────────────────────────
#  ExternalDNS — IAM Policy + Role (IRSA)
#  Automatically creates Route 53 records from
#  Ingress annotations. Replaces manual Phase 11
#  console clicking.
# ──────────────────────────────────────────────

variable "domain_name" {
  description = "Domain name for Route 53 hosted zone"
  type        = string
  default     = "platinum-consults.com"
}

# Route 53 Hosted Zone — looked up by name, NOT created here.
# The zone is created once in bootstrap.sh and persists across all deployments,
# so nameservers at the registrar never need to change.
data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

# IAM Policy for ExternalDNS
resource "aws_iam_policy" "external_dns" {
  name        = "${var.cluster_name}-external-dns-policy"
  description = "IAM policy for ExternalDNS to manage Route 53 records"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets"
        ]
        Resource = [
          "arn:aws:route53:::hostedzone/${data.aws_route53_zone.main.zone_id}"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ListHostedZones",
          "route53:ListResourceRecordSets",
          "route53:ListTagsForResource"
        ]
        Resource = ["*"]
      }
    ]
  })

  tags = {
    Project = "nimbus-retail-platform"
  }
}

# IAM Role for ExternalDNS service account (IRSA)
resource "aws_iam_role" "external_dns" {
  name = "${var.cluster_name}-external-dns-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = local.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider}:aud" = "sts.amazonaws.com"
          "${local.oidc_provider}:sub" = "system:serviceaccount:kube-system:external-dns"
        }
      }
    }]
  })

  tags = {
    Project = "nimbus-retail-platform"
  }
}

resource "aws_iam_role_policy_attachment" "external_dns" {
  policy_arn = aws_iam_policy.external_dns.arn
  role       = aws_iam_role.external_dns.name
}
