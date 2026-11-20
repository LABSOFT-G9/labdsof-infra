terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # State bucket from bootstrap/. Its name contains the account ID, so it is
  # passed at init: terraform init -backend-config="bucket=<state bucket>"
  backend "s3" {
    key          = "dev/terraform.tfstate"
    region       = "eu-north-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "bmc"
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "LABSOFT-G9/labdsof-infra"
    }
  }
}
