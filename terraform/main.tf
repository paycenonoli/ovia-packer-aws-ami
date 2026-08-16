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

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name = "availability-zone"
    values = [
      "us-east-1a",
      "us-east-1b",
      "us-east-1c",
      "us-east-1d",
      "us-east-1f"
    ]
  }
}

resource "aws_launch_template" "app" {
  name_prefix   = "ovia-packer-app-"
  image_id      = var.ami_id
  instance_type = "t3.micro"

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "ovia-packer-app"
    }
  }
}

resource "aws_autoscaling_group" "app" {
  name = "ovia-packer-app"

  min_size         = 1
  max_size         = 1
  desired_capacity = 1

  vpc_zone_identifier = data.aws_subnets.default.ids

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 0
    }
  }

  tag {
    key                 = "Name"
    value               = "ovia-packer-app"
    propagate_at_launch = true
  }
}
