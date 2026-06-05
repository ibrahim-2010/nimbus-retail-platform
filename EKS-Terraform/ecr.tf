# ──────────────────────────────────────────────
#  ECR — One repository per Nimbus service
# ──────────────────────────────────────────────

locals {
  nimbus_services = toset([
    "auth-service",
    "audit-service",
    "catalog-service",
    "cart-service",
    "order-service",
    "notification-service",
  ])
}

resource "aws_ecr_repository" "services" {
  for_each = local.nimbus_services

  name                 = "nimbus/${each.key}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project = "nimbus-retail"
  }
}

resource "aws_ecr_lifecycle_policy" "services" {
  for_each   = aws_ecr_repository.services
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# ──────────────────────────────────────────────
#  ECR — operator-copilot (Phase 3 AI agent)
#  Separate from nimbus/* — image is built and
#  pushed manually from operator-copilot-starter.
# ──────────────────────────────────────────────

resource "aws_ecr_repository" "operator_copilot" {
  name                 = "operator-copilot"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project = "nimbus-retail"
  }
}

resource "aws_ecr_lifecycle_policy" "operator_copilot" {
  repository = aws_ecr_repository.operator_copilot.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
