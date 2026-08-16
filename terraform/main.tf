terraform {
  backend "s3" {
    bucket       = "ovia-packer-terraform-state-417521971848"
    key          = "ovia-packer/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

resource "aws_instance" "app" {
  ami           = var.ami_id
  instance_type = var.instance_type

  tags = {
    Name = "ovia-packer-app"
  }
}
