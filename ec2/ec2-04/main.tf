# ec2-04 — instance + data volume + snapshot + AMI (pair of ec2-03)
# Differs from ec2-03 by also creating an aws_ami_from_instance.
# Posture expectation: produces BOTH an aws_ec2_snapshot and an aws_ec2_image.
# Both are protection artifacts (role "snapshot") and both must be excluded
# from the protected/unprotected counts. This is the fixture that catches an
# AMI being miscounted as an unprotected resource.
#
# COST (us-east-1 on-demand list prices, before any free tier or credits)
#   Rates used: t3.micro $0.0104/hr | public IPv4 $0.005/hr | gp3 $0.08/GB-mo
#   ($0.00011/GB-hr) | snapshot / AWS Backup $0.05/GB-mo ($0.000068/GB-hr) |
#   cross-region copy transfer $0.02/GB. Vaults, plans, DLM, IAM, locks: free.
#   EC2 and EBS bill per second (60 s minimum); there is no creation fee.
#   One-time at creation : $0.00 (creating the AMI is free; you pay for its snapshots)
#   Per hour as deployed : $0.01645/hr  RUNNING: t3.micro + public IPv4 + 9 GB gp3 + ~1 GB snapshots (AMI root 1 GB; data snapshots ~0 GB while empty)
#   Per hour if stopped  : $0.00105/hr  (no compute or public IPv4; EBS, snapshots and backups still bill)
#   Per day / month      : ~$0.39/day | ~$12.01/month (as deployed)
#   TOTAL per hour       : $0.01645/hr as deployed (instance left running) | $0.00105/hr if you stop it
#   Stop the instance in the console to drop to ~$0.00105/hr.

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
  description = "Free-tier eligible instance type"
  type        = string
  default     = "t3.micro"
}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_vpc" "default" {
  default = true
}

# Only subnets in AZs that offer the instance type. Subnet order is not
# guaranteed, and us-east-1e does not offer t3.micro.
data "aws_ec2_instance_type_offerings" "supported" {
  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }

  location_type = "availability-zone"
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "availability-zone"
    values = data.aws_ec2_instance_type_offerings.supported.locations
  }
}

resource "aws_security_group" "this" {
  name        = "ft-posture-ec2-04"
  description = "Egress only"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "ft-posture-ec2-04"
    Fixture = "posture-test"
  }
}

resource "aws_instance" "this" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.this.id]

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    delete_on_termination = true
    encrypted             = true

    tags = {
      Name    = "ec2-04-root"
      Fixture = "posture-test"
    }
  }

  tags = {
    Name       = "ec2-04"
    Fixture    = "posture-test"
    Protection = "manual-snapshot-ami"
    FreeTier   = "true"
  }
}

resource "aws_ebs_volume" "data" {
  availability_zone = aws_instance.this.availability_zone
  size              = 1
  type              = "gp3"
  encrypted         = true

  tags = {
    Name       = "ec2-04-data"
    Fixture    = "posture-test"
    Protection = "manual-snapshot-ami"
    FreeTier   = "true"
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.this.id
}

resource "aws_ebs_snapshot" "data" {
  volume_id   = aws_ebs_volume.data.id
  description = "posture fixture snapshot - ec2-04"

  tags = {
    Name    = "ec2-04-data-snap"
    Fixture = "posture-test"
    Role    = "protection-artifact"
  }

  timeouts {
    create = "30m"
  }
}

resource "aws_ami_from_instance" "this" {
  name                    = "ft-posture-ec2-04-ami"
  source_instance_id      = aws_instance.this.id
  snapshot_without_reboot = true

  tags = {
    Name    = "ec2-04-ami"
    Fixture = "posture-test"
    Role    = "protection-artifact"
  }

  timeouts {
    create = "60m"
  }
}

output "instance_id" {
  value = aws_instance.this.id
}

output "snapshot_id" {
  value = aws_ebs_snapshot.data.id
}

output "ami_id" {
  value = aws_ami_from_instance.this.id
}

output "instance_state" {
  description = "Instance state after apply. Every stack leaves its instance running."
  value       = aws_instance.this.instance_state
}

output "cost_estimate" {
  description = "Approximate cost, us-east-1 list prices"
  value = join("\n", [
    "One-time at creation : $0.00 (creating the AMI is free; you pay for its snapshots)",
    "Per hour as deployed : $0.01645/hr  RUNNING: t3.micro + public IPv4 + 9 GB gp3 + ~1 GB snapshots (AMI root 1 GB; data snapshots ~0 GB while empty)",
    "Per hour if stopped  : $0.00105/hr  (no compute or public IPv4; EBS, snapshots and backups still bill)",
    "Per day / month      : ~$0.39/day | ~$12.01/month (as deployed)",
    "TOTAL per hour       : $0.01645/hr as deployed (instance left running) | $0.00105/hr if you stop it",
  ])
}
