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

# Enable ECR enhanced scanning (Inspector v2) for all repositories.
# Inspector continuously rescans images against NVD/Amazon Security Advisories —
# provides BFSI-grade continuous vulnerability monitoring beyond push-time Trivy.
resource "aws_ecr_registry_scanning_configuration" "enhanced" {
  scan_type = "ENHANCED"

  rule {
    scan_frequency = "CONTINUOUS_SCAN"
    repository_filter {
      filter      = "${var.project}-${var.environment}/*"
      filter_type = "WILDCARD"
    }
  }
}

# Pull-through cache for public images routed via ECR (reduces external egress,
# satisfies PCI-DSS requirement to control third-party component sources).
resource "aws_ecr_pull_through_cache_rule" "ecr_public" {
  #checkov:skip=CKV_AWS_293: No upstream credential required for ECR Public
  ecr_repository_prefix = "ecr-public"
  upstream_registry_url = "public.ecr.aws"
}

resource "aws_ecr_pull_through_cache_rule" "docker_hub" {
  count = var.dockerhub_secret_arn != "" ? 1 : 0

  ecr_repository_prefix = "docker-hub"
  upstream_registry_url = "registry-1.docker.io"
  credential_arn        = var.dockerhub_secret_arn
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
