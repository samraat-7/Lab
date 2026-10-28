# ec2-06 — standalone EBS volume, no instance, no protection
# One encrypted 1 GB gp3 volume that is never attached to anything.
# Posture expectation: aws_ec2_volume scored on its own (no parent instance),
# copy_count 0 and no recovery points. An unattached volume must still be
# found and reported as unprotected.
#
# COST (us-east-1 on-demand list prices, before any free tier or credits)
#   Rates used: gp3 $0.08/GB-mo ($0.00011/GB-hr). No instance, so no compute
#   and no public IPv4. EBS bills per second (60 s minimum); there is no
#   creation fee, and an unattached volume bills the same as an attached one.
#   One-time at creation : $0.00
#   Per hour as deployed : $0.00011/hr  1 GB gp3 volume, unattached
#   Per day / month      : ~$0.0026/day | ~$0.08/month (as deployed)
#   TOTAL per hour       : $0.00011/hr as deployed (nothing to stop; destroy to stop billing)

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

variable "volume_size" {
  description = "Volume size in GB - 1 is the gp3 minimum"
  type        = number
  default     = 1

  validation {
    condition     = var.volume_size >= 1
    error_message = "gp3 volumes are at least 1 GiB."
  }
}

# A volume lives in one AZ. With no instance there is no instance-type
# restriction, so the first available AZ in the region is fine.
data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_ebs_volume" "this" {
  availability_zone = data.aws_availability_zones.available.names[0]
  size              = var.volume_size
  type              = "gp3"
  encrypted         = true

  tags = {
    Name       = "ec2-06-ebs"
    Fixture    = "posture-test"
    Protection = "none"
  }
}

output "volume_id" {
  value = aws_ebs_volume.this.id
}

output "volume_arn" {
  value = aws_ebs_volume.this.arn
}

output "availability_zone" {
  value = aws_ebs_volume.this.availability_zone
}

output "attached_to" {
  description = "Always none: this volume is deliberately left unattached."
  value       = "none (state: available)"
}

output "cost_estimate" {
  description = "Approximate cost, us-east-1 list prices"
  value = join("\n", [
    "One-time at creation : $0.00",
    "Per hour as deployed : $0.00011/hr  1 GB gp3 volume, unattached",
    "Per day / month      : ~$0.0026/day | ~$0.08/month (as deployed)",
    "TOTAL per hour       : $0.00011/hr as deployed (nothing to stop; destroy to stop billing)",
  ])
}
