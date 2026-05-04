# ──────────────────────────────────────────────
#  AWS Load Balancer Controller — IAM Policy + Role (IRSA)
#  Scoped with full ELB + EC2 permissions from day one
#  (fixes the v2.7.1 policy gap that caused ALB provisioning failures)
# ──────────────────────────────────────────────

resource "aws_iam_policy" "alb_controller" {
  name        = "${var.cluster_name}-alb-controller-policy"
  description = "IAM policy for AWS Load Balancer Controller on EKS"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          # Elastic Load Balancing — full access (covers DescribeListenerAttributes)
          "elasticloadbalancing:*",

          # EC2 — describe + security group management
          "ec2:Describe*",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:CreateSecurityGroup",
          "ec2:DeleteSecurityGroup",
          "ec2:CreateTags",
          "ec2:DeleteTags",
          "ec2:GetCoipPoolUsage",
          "ec2:DescribeCoipPools",

          # IAM — service-linked role for ELB
          "iam:CreateServiceLinkedRole",

          # ACM — certificate discovery for HTTPS
          "acm:ListCertificates",
          "acm:DescribeCertificate",
          "acm:GetCertificate",

          # WAF — web application firewall integration
          "wafv2:GetWebACL",
          "wafv2:GetWebACLForResource",
          "wafv2:AssociateWebACL",
          "wafv2:DisassociateWebACL",
          "waf-regional:GetWebACL",
          "waf-regional:GetWebACLForResource",
          "waf-regional:AssociateWebACL",
          "waf-regional:DisassociateWebACL",

          # Shield — DDoS protection
          "shield:GetSubscriptionState",
          "shield:DescribeProtection",
          "shield:CreateProtection",
          "shield:DeleteProtection",

          # Resource tagging
          "tag:GetResources",
          "tag:TagResources",

          # Cognito — user pool integration
          "cognito-idp:DescribeUserPoolClient",
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Project = "cloud-native-eks"
  }
}

# IAM Role for the ALB controller service account (IRSA)
resource "aws_iam_role" "alb_controller" {
  name = "${var.cluster_name}-alb-controller-role"

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
          "${local.oidc_provider}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
        }
      }
    }]
  })

  tags = {
    Project = "cloud-native-eks"
  }
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  policy_arn = aws_iam_policy.alb_controller.arn
  role       = aws_iam_role.alb_controller.name
}
