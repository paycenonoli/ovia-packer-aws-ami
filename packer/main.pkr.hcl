packer {
  required_plugins {
    amazon = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

source "amazon-ebs" "ubuntu" {
  region = var.aws_region

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }

    owners      = ["099720109477"]
    most_recent = true
  }

  instance_type = var.instance_type

  ssh_username = "ubuntu"

  ami_name = "${var.ami_name_prefix}-{{timestamp}}"
}

build {
  sources = [
    "source.amazon-ebs.ubuntu"
  ]
}
