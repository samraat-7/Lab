# s3-03 — versioning + lifecycle + SSE-S3 encryption
# Differs from s3-02 by a lifecycle rule (expires noncurrent versions, aborts
# stale multipart uploads) and aws_s3_bucket_server_side_encryption_configuration.
# Uses AES256 (SSE-S3) deliberately: a customer-managed KMS key costs $1/month,
# so SSE-KMS with a CMK would break the free-tier constraint.
# Posture expectation: encryption is a security signal, not a copy — the
# 3-2-1-1 axes match s3-02, plus a readable retention_days from the lifecycle rule.
# Free tier: the lifecycle rule only expires old versions and aborts stale
# multipart uploads, which is free; old versions are billed until they expire.

# Cost (approx. us-east-1 list prices, no free tier applied):
#   Creation:         $0.00 (bucket, public block, versioning, lifecycle, SSE-S3 are free)
#   Per hour, empty:  $0.00
#   Per hour, 1 GB:   ~$0.000032 (~$0.023/month: 1 S3 copy x $0.023 per GB-month)
#   Other:            PUT/COPY requests $0.005 per 1,000
#                     lifecycle expiration and SSE-S3 are free

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

variable "noncurrent_retention_days" {
  description = "Days to keep noncurrent object versions"
  type        = number
  default     = 90
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "this" {
  bucket = "${var.name_prefix}-s3-03-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name       = "s3-03"
    Fixture    = "posture-test"
    Protection = "versioning-lifecycle-sse"
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

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket     = aws_s3_bucket.this.id
  depends_on = [aws_s3_bucket_versioning.this]

  rule {
    id     = "expire-noncurrent"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
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
    "Creation:         $0.00 (bucket, public block, versioning, lifecycle, SSE-S3 are free)",
    "Per hour, empty:  $0.00",
    "Per hour, 1 GB:   ~$0.000032 (~$0.023/month: 1 S3 copy x $0.023 per GB-month)",
    "Other:            PUT/COPY requests $0.005 per 1,000",
    "                  lifecycle expiration and SSE-S3 are free",
  ])
}
