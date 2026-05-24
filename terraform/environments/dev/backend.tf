terraform {
  backend "s3" {
    bucket = "intelliops-tfstate-cloudus"
    key    = "dev/terraform.tfstate"
    region = "us-east-1"

    # S3 native locking — requires Terraform >= 1.10, no DynamoDB table needed
    use_lockfile = true
  }
}
