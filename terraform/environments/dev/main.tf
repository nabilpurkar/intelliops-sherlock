module "vpc" {
  source = "../../modules/vpc"

  environment = "dev"
  project     = "intelliops"

  vpc_cidr = "10.0.0.0/16"

  availability_zones   = ["us-east-1a", "us-east-1b", "us-east-1c"]
  public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  private_subnet_cidrs = ["10.0.10.0/24", "10.0.20.0/24", "10.0.30.0/24"]

  # Single NAT Gateway is the module default — cost-saving for dev.
  # For staging/prod, deploy a separate module instance per AZ for HA.

  flow_log_retention_days = 30
}
