variable "aws_region" {
  type        = string
  description = "AWS region where the AMI will be built"
  default     = "us-east-1"
}

variable "instance_type" {
  type        = string
  description = "Temporary EC2 instance type used by Packer"
  default     = "t3.micro"
}

variable "ami_name_prefix" {
  type        = string
  description = "Prefix for the generated AMI name"
  default     = "ovia-packer-ubuntu"
}
