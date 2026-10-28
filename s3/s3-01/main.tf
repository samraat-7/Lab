# s3-01 — bare bucket, no data protection (public access fully blocked)
# Posture expectation: scored, copy_count 0, no versioning, no immutability.
# Free tier: bucket itself is free; 5 GB Standard storage allowance shared account-wide.

# Cost (approx. us-east-1 list prices, no free tier applied):
#   Creation:         $0.00 (bucket, public block are free)
#   Per hour, empty:  $0.00
#   Per hour, 1 GB:   ~$0.000032 (~$0.023/month: 1 S3 copy x $0.023 per GB-month)
#   Other:            PUT/COPY requests $0.005 per 1,000

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
  bucket = "${var.name_prefix}-s3-01-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name       = "s3-01"
    Fixture    = "posture-test"
    Protection = "none"
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

output "bucket_name" {
  value = aws_s3_bucket.this.id
}

output "bucket_arn" {
  value = aws_s3_bucket.this.arn
}

output "cost_estimate" {
  description = "Approximate us-east-1 list prices, no free tier applied."
  value = join("\n", [
    "Creation:         $0.00 (bucket, public block are free)",
    "Per hour, empty:  $0.00",
    "Per hour, 1 GB:   ~$0.000032 (~$0.023/month: 1 S3 copy x $0.023 per GB-month)",
    "Other:            PUT/COPY requests $0.005 per 1,000",
  ])
}
