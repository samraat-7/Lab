# s3-07 — bucket + S3 Object Lock
#
# Object Lock can only be switched on when the bucket is created, and it turns
# versioning on with it. Every new object gets a default retention in
# GOVERNANCE mode, so it cannot be overwritten or deleted until the retention
# ends, unless the caller has s3:BypassGovernanceRetention.
# GOVERNANCE (not COMPLIANCE) is deliberate: force_destroy bypasses it, so
# `terraform destroy` / down.sh still works. COMPLIANCE would block destroy
# until every object's retention has passed.
# Posture expectation: copy_count 0, versioning on, immutable_status 1.
# Free tier: Object Lock itself is free; locked versions count against the
# 5 GB Standard allowance until they expire.

# Cost (approx. us-east-1 list prices, no free tier applied):
#   Creation:         $0.00 (bucket, public block, versioning, object lock are free)
#   Per hour, empty:  $0.00
#   Per hour, 1 GB:   ~$0.000032 (~$0.023/month: 1 S3 copy x $0.023 per GB-month)
#   Other:            PUT/COPY requests $0.005 per 1,000
#                     locked versions are billed until retention ends and you can delete them

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

variable "lock_mode" {
  description = "Default Object Lock retention mode: GOVERNANCE or COMPLIANCE"
  type        = string
  default     = "GOVERNANCE"

  validation {
    condition     = contains(["GOVERNANCE", "COMPLIANCE"], var.lock_mode)
    error_message = "lock_mode must be GOVERNANCE or COMPLIANCE."
  }
}

variable "lock_retention_days" {
  description = "Default retention applied to every new object version"
  type        = number
  default     = 1
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "this" {
  bucket              = "${var.name_prefix}-s3-07-${data.aws_caller_identity.current.account_id}"
  object_lock_enabled = true
  force_destroy       = true

  tags = {
    Name       = "s3-07"
    Fixture    = "posture-test"
    Protection = "object-lock"
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

# Already on because of Object Lock; declared so Terraform tracks it.
resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    default_retention {
      mode = var.lock_mode
      days = var.lock_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

output "bucket_name" {
  value = aws_s3_bucket.this.id
}

output "bucket_arn" {
  value = aws_s3_bucket.this.arn
}

output "object_lock" {
  value = "${var.lock_mode}, ${var.lock_retention_days} day(s) default retention"
}

output "test_commands" {
  description = "Upload an object, check its retention, and see the lock reject a delete."
  value = join("\n", [
    "echo hello > test.txt",
    "aws s3api put-object --bucket ${aws_s3_bucket.this.id} --key test.txt --body test.txt --region ${var.region}",
    "aws s3api list-object-versions --bucket ${aws_s3_bucket.this.id} --prefix test.txt --query 'Versions[].VersionId' --output text --region ${var.region}",
    "aws s3api get-object-retention --bucket ${aws_s3_bucket.this.id} --key test.txt --version-id <version-id> --region ${var.region}",
    "# Expected to FAIL with AccessDenied while the retention is active:",
    "aws s3api delete-object --bucket ${aws_s3_bucket.this.id} --key test.txt --version-id <version-id> --region ${var.region}",
  ])
}

output "cost_estimate" {
  description = "Approximate us-east-1 list prices, no free tier applied."
  value = join("\n", [
    "Creation:         $0.00 (bucket, public block, versioning, object lock are free)",
    "Per hour, empty:  $0.00",
    "Per hour, 1 GB:   ~$0.000032 (~$0.023/month: 1 S3 copy x $0.023 per GB-month)",
    "Other:            PUT/COPY requests $0.005 per 1,000",
    "                  locked versions are billed until retention ends and you can delete them",
  ])
}
