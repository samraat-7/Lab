# ec2-01 — bare instance, root EBS only, no protection
# Posture expectation: aws_ec2_instance and aws_ec2_volume both scored,
# both with copy_count 0 and no recovery points.
#
# COST (us-east-1 on-demand list prices, before any free tier or credits)
#   Rates used: t3.micro $0.0104/hr | public IPv4 $0.005/hr | gp3 $0.08/GB-mo
#   ($0.00011/GB-hr) | snapshot / AWS Backup $0.05/GB-mo ($0.000068/GB-hr) |
#   cross-region copy transfer $0.02/GB. Vaults, plans, DLM, IAM, locks: free.
#   EC2 and EBS bill per second (60 s minimum); there is no creation fee.
#   One-time at creation : $0.00
#   Per hour as deployed : $0.01628/hr  RUNNING: t3.micro + public IPv4 + 8 GB gp3 root
#   Per hour if stopped  : $0.00088/hr  (no compute or public IPv4; EBS, snapshots and backups still bill)
#   Per day / month      : ~$0.39/day | ~$11.88/month (as deployed)
#   TOTAL per hour       : $0.01628/hr as deployed (instance left running) | $0.00088/hr if you stop it
#   Stop the instance in the console to drop to ~$0.00088/hr.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  description = "Region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "Instance type. t3.micro and t2.micro are the cheapest widely available."
  type        = string
  default     = "t3.micro"
}

variable "root_volume_size" {
  description = "Root volume size in GB - 8 is the AL2023 AMI minimum"
  type        = number
  default     = 8

  validation {
    condition     = var.root_volume_size >= 8
    error_message = "The Amazon Linux 2023 AMI is 8 GiB, so the root volume cannot be smaller than 8."
  }
}

# Amazon Linux 2023, resolved from the public SSM parameter so the AMI id is
# never hardcoded and never goes stale.
#
# nonsensitive() because the parameter is a PUBLIC AWS-published AMI id, not a
# secret. Without it the plan prints "ami = (sensitive value)" and you cannot
# confirm which image you are about to launch.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_vpc" "default" {
  default = true
}

# ---------------------------------------------------------------------------
# THE FIX
#
# Not every Availability Zone offers every instance type. us-east-1e, for
# example, predates the Nitro generation and does not offer t3.micro at all.
#
# The default VPC has a subnet in every AZ, and aws_subnets returns them in no
# guaranteed order, so taking .ids[0] is a lottery: it works in one account and
# fails in another with
#
#   Unsupported: Your requested instance type (t3.micro) is not supported in
#   your requested Availability Zone (us-east-1e)
#
# So: ask EC2 which AZs actually offer this instance type, then only consider
# subnets in those AZs. This is self-correcting across regions and accounts.
# ---------------------------------------------------------------------------

data "aws_ec2_instance_type_offerings" "supported" {
  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }

  location_type = "availability-zone"
}

data "aws_subnets" "usable" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  # Only subnets in an AZ that offers var.instance_type.
  filter {
    name   = "availability-zone"
    values = data.aws_ec2_instance_type_offerings.supported.locations
  }
}

resource "aws_security_group" "this" {
  name        = "ft-posture-ec2-01"
  description = "Egress only - no inbound, nothing to reach this host"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "ft-posture-ec2-01"
    Fixture = "posture-test"
  }
}

resource "aws_instance" "this" {
  ami                    = nonsensitive(data.aws_ssm_parameter.al2023.value)
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.usable.ids[0]
  vpc_security_group_ids = [aws_security_group.this.id]

  # IMDSv2 only. Costs nothing and removes a finding that would otherwise
  # muddy a backup-posture demo with a security one.
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    delete_on_termination = true
    encrypted             = true

    tags = {
      Name    = "ec2-01-root"
      Fixture = "posture-test"
    }
  }

  tags = {
    Name       = "ec2-01"
    Fixture    = "posture-test"
    Protection = "none"
  }

  # Fails at plan time with a readable message instead of an "index out of
  # range" error if the filters leave nothing to launch into.
  lifecycle {
    precondition {
      condition     = length(data.aws_subnets.usable.ids) > 0
      error_message = "No subnet in ${var.region} sits in an AZ that offers ${var.instance_type}. Try t2.micro, or pick another region."
    }
  }
}

# ---------------------------------------------------------------------------
# Keep the instance running. This also starts it again if an earlier version
# of this script left it stopped.
#
# ---------------------------------------------------------------------------

resource "aws_ec2_instance_state" "this" {
  instance_id = aws_instance.this.id
  state       = "running"
}

output "instance_id" {
  value = aws_instance.this.id
}

output "root_volume_id" {
  value = aws_instance.this.root_block_device[0].volume_id
}

output "availability_zone" {
  description = "Which AZ it actually landed in - useful when debugging the next fixture."
  value       = aws_instance.this.availability_zone
}

output "ami_id" {
  description = "The AL2023 image this launched from."
  value       = nonsensitive(data.aws_ssm_parameter.al2023.value)
}

output "instance_state" {
  description = "Instance state after apply. Every stack leaves its instance running."
  value       = aws_ec2_instance_state.this.state
}

output "cost_estimate" {
  description = "Approximate cost, us-east-1 list prices"
  value = join("\n", [
    "One-time at creation : $0.00",
    "Per hour as deployed : $0.01628/hr  RUNNING: t3.micro + public IPv4 + 8 GB gp3 root",
    "Per hour if stopped  : $0.00088/hr  (no compute or public IPv4; EBS, snapshots and backups still bill)",
    "Per day / month      : ~$0.39/day | ~$11.88/month (as deployed)",
    "TOTAL per hour       : $0.01628/hr as deployed (instance left running) | $0.00088/hr if you stop it",
  ])
}
