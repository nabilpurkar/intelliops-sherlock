locals {
  common_tags = merge(
    {
      env        = var.environment
      project    = var.project
      owner      = "devops-lead"
      managed-by = "terraform"
    },
    var.tags
  )
}

resource "aws_ecr_repository" "services" {
  #checkov:skip=CKV_AWS_136: KMS encryption disabled for dev; enable for staging/prod
  #checkov:skip=CKV_AWS_51: MUTABLE tags allow :latest pushes in dev; set IMMUTABLE for prod
  for_each = toset(var.services)

  name                 = "${var.project}-${var.environment}/${each.key}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(local.common_tags, { Name = "${var.project}-${var.environment}-${each.key}" })
}

resource "aws_ecr_lifecycle_policy" "services" {
  for_each   = aws_ecr_repository.services
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
