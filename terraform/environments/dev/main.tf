module "vpc" {
  source = "../../modules/vpc"

  environment = "dev"
  project     = "intelliops"

  vpc_cidr = "10.0.0.0/16"

  availability_zones  = ["us-east-1a", "us-east-1b", "us-east-1c"]
  public_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  # private_subnet_cidrs = ["10.0.10.0/24", "10.0.20.0/24", "10.0.30.0/24"] # disabled for dev

  eks_cluster_name = "intelliops-dev"

  # Single NAT Gateway is the module default — cost-saving for dev.
  # For staging/prod, deploy a separate module instance per AZ for HA.

  flow_log_retention_days = 30
}

# ─── Dev EC2 Access — IPv6 ingress ───────────────────────────────────────────

data "aws_security_group" "dev_ec2_default" {
  name   = "default"
  vpc_id = "vpc-055aeedd081a8d339"
}

resource "aws_security_group_rule" "dev_machine_ipv6_all_tcp" {
  description       = "Dev machine IPv6 - all TCP access"
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
  ipv6_cidr_blocks  = ["2401:4900:8814:ee83:d925:44d:8999:db27/128"]
  security_group_id = data.aws_security_group.dev_ec2_default.id
}

# NOTE: AWS EKS public_access_cidrs only accepts IPv4. The public endpoint
# is open to 0.0.0.0/0 but protected by IAM/RBAC — no unauthenticated access.

module "ecr" {
  source = "../../modules/ecr"

  environment = "dev"
  project     = "intelliops"
  services    = ["order-service", "payment-service", "inventory-service", "load-generator"]
}

module "iam" {
  source = "../../modules/iam"

  github_repo          = "nabilpurkar/intelliops-sherlock"
  aws_account_id       = "007066145518"
  aws_region           = "us-east-1"
  ecr_repo_prefix      = "intelliops-dev"
  create_oidc_provider = true
  environment          = "dev"
  project              = "intelliops"

  # EKS IRSA — wired from EKS module outputs
  eks_oidc_provider_arn = module.eks.oidc_provider_arn
  eks_oidc_provider_url = module.eks.oidc_provider_url
  cluster_name          = module.eks.cluster_name
  route53_zone_id       = "Z09505612LJLVLH4DJD2G"
}

module "secrets" {
  source = "../../modules/secrets"

  environment             = "dev"
  project                 = "intelliops"
  recovery_window_in_days = 7
  # kms_key_id — omitted for dev (uses aws/secretsmanager managed key)
  # pass module.eks.kms_key_arn here for staging/prod once KMS is enabled
}

module "eks" {
  source = "../../modules/eks"

  cluster_name        = "intelliops-dev"
  environment         = "dev"
  project             = "intelliops"
  vpc_id              = module.vpc.vpc_id
  private_subnet_ids  = module.vpc.public_subnet_ids # using public subnets in dev (no private subnets)
  allowed_cidr_blocks = ["172.31.0.0/16"]

  endpoint_public_access = true

  node_instance_type = "t3.large"
  node_min_size      = 2
  node_max_size      = 6
  node_desired_size  = 4
}
