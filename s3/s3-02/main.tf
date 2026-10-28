# s3-02 — versioning enabled
# Differs from s3-01 by one block: aws_s3_bucket_versioning.
# Posture expectation: versioning gives a recovery path but no separate copy,
# so copy_count stays low and immutable_status stays 0.
# Free tier: versioning is free; each version counts against the 5 GB allowance.

# Cost (approx. us-east-1 list prices, no free tier applied):
#   Creation:         $0.00 (bucket, public block, versioning are free)
#   Per hour, empty:  $0.00
#   Per hour, 1 GB:   ~$0.000032 (~$0.023/month: 1 S3 copy x $0.023 per GB-month)
#   Other:            PUT/COPY requests $0.005 per 1,000
#                     every old version is billed as storage

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

variable "name_prefix" {
  description = "Prefix for the bucket name"
  type        = string
  default     = "ft-posture"
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "this" {
  bucket = "${var.name_prefix}-s3-02-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name       = "s3-02"
    Fixture    = "posture-test"
    Protection = "versioning"
    FreeTier   = "true"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}

output "bucket_name" {
  value = aws_s3_bucket.this.id
}

output "bucket_arn" {
  value = aws_s3_bucket.this.arn
}

output "cost_estimate" {
  description = "Approximate us-east-1 list prices, no free tier applied."
  value = join("\n", [
    "Creation:         $0.00 (bucket, public block, versioning are free)",
    "Per hour, empty:  $0.00",
    "Per hour, 1 GB:   ~$0.000032 (~$0.023/month: 1 S3 copy x $0.023 per GB-month)",
    "Other:            PUT/COPY requests $0.005 per 1,000",
    "                  every old version is billed as storage",
  ])
}
