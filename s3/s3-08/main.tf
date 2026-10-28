# s3-08 — CRR + SRR + S3 Object Lock
#
#   s3-08 (us-east-1) --CRR--> s3-08-replica-crr (us-west-2)   different region
#                     --SRR--> s3-08-replica-srr (us-east-1)   same region
#
# All three buckets have Object Lock with a GOVERNANCE default retention.
# S3 requires Object Lock on the destinations to replicate locked objects, and
# replicas keep the source object's retention settings.
# Only objects written after apply are replicated.
# GOVERNANCE is deliberate: force_destroy bypasses it, so down.sh still works.
# Posture expectation: copy_count 2, geo_separation > 0, immutable_status 1.
# Free tier: empty buckets are free; every object is stored three times and
# the CRR copy pays ~$0.02/GB transfer, so keep objects tiny.

# Cost (approx. us-east-1 list prices, no free tier applied):
#   Creation:         $0.00 (3 buckets, versioning, object lock, replication rules, IAM role are free)
#   Per hour, empty:  $0.00
#   Per hour, 1 GB:   ~$0.000095 (~$0.069/month: 3 S3 copies x $0.023 per GB-month)
#   Other:            PUT/COPY requests $0.005 per 1,000
#                     CRR transfer ~$0.02 per GB replicated (one-time per GB)

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

provider "aws" {
  alias  = "replica"
  region = var.replica_region
}

variable "region" {
  description = "Region of the source bucket and the same-region replica"
  type        = string
  default     = "us-east-1"
}

variable "replica_region" {
  description = "Region of the cross-region replica. Must differ from region."
  type        = string
  default     = "us-west-2"

  validation {
    condition     = var.replica_region != var.region
    error_message = "replica_region must differ from region."
  }
}

variable "name_prefix" {
  description = "Prefix for the bucket name"
  type        = string
  default     = "ft-posture"
}

variable "lock_mode" {
  description = "Default Object Lock retention mode on all three buckets: GOVERNANCE or COMPLIANCE"
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

locals {
  account_id = data.aws_caller_identity.current.account_id
}

# ---------------------------------------------------------------------------
# Source bucket
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "this" {
  bucket              = "${var.name_prefix}-s3-08-${local.account_id}"
  object_lock_enabled = true
  force_destroy       = true

  tags = {
    Name       = "s3-08"
    Fixture    = "posture-test"
    Protection = "replication-crr-srr-object-lock"
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

# ---------------------------------------------------------------------------
# Replica 1: cross-region (CRR)
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "crr" {
  provider = aws.replica

  bucket              = "${var.name_prefix}-s3-08-replica-crr-${local.account_id}"
  object_lock_enabled = true
  force_destroy       = true

  tags = {
    Name       = "s3-08-replica-crr"
    Fixture    = "posture-test"
    Protection = "replication-target-cross-region"
    FreeTier   = "true"
  }
}

resource "aws_s3_bucket_public_access_block" "crr" {
  provider = aws.replica

  bucket = aws_s3_bucket.crr.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "crr" {
  provider = aws.replica

  bucket = aws_s3_bucket.crr.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "crr" {
  provider = aws.replica

  bucket = aws_s3_bucket.crr.id

  rule {
    default_retention {
      mode = var.lock_mode
      days = var.lock_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.crr]
}

# ---------------------------------------------------------------------------
# Replica 2: same-region (SRR)
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "srr" {
  bucket              = "${var.name_prefix}-s3-08-replica-srr-${local.account_id}"
  object_lock_enabled = true
  force_destroy       = true

  tags = {
    Name       = "s3-08-replica-srr"
    Fixture    = "posture-test"
    Protection = "replication-target-same-region"
    FreeTier   = "true"
  }
}

resource "aws_s3_bucket_public_access_block" "srr" {
  bucket = aws_s3_bucket.srr.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "srr" {
  bucket = aws_s3_bucket.srr.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "srr" {
  bucket = aws_s3_bucket.srr.id

  rule {
    default_retention {
      mode = var.lock_mode
      days = var.lock_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.srr]
}

# ---------------------------------------------------------------------------
# IAM role S3 assumes to copy objects. Replicating locked objects also needs
# GetObjectRetention / GetObjectLegalHold on the source.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "replication" {
  name               = "${var.name_prefix}-s3-08-replication"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "replication" {
  statement {
    actions   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
    resources = [aws_s3_bucket.this.arn]
  }

  statement {
    actions = [
      "s3:GetObjectVersionForReplication",
      "s3:GetObjectVersionAcl",
      "s3:GetObjectVersionTagging",
      "s3:GetObjectRetention",
      "s3:GetObjectLegalHold",
    ]
    resources = ["${aws_s3_bucket.this.arn}/*"]
  }

  statement {
    actions = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"]
    resources = [
      "${aws_s3_bucket.crr.arn}/*",
      "${aws_s3_bucket.srr.arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "replication" {
  name   = "${var.name_prefix}-s3-08-replication"
  role   = aws_iam_role.replication.id
  policy = data.aws_iam_policy_document.replication.json
}

# ---------------------------------------------------------------------------
# Replication rules (on the source bucket)
# ---------------------------------------------------------------------------

resource "aws_s3_bucket_replication_configuration" "this" {
  depends_on = [
    aws_s3_bucket_versioning.this,
    aws_s3_bucket_versioning.crr,
    aws_s3_bucket_versioning.srr,
    aws_s3_bucket_object_lock_configuration.this,
    aws_s3_bucket_object_lock_configuration.crr,
    aws_s3_bucket_object_lock_configuration.srr,
    aws_iam_role_policy.replication,
  ]

  bucket = aws_s3_bucket.this.id
  role   = aws_iam_role.replication.arn

  rule {
    id       = "to-other-region"
    priority = 1
    status   = "Enabled"

    filter {}

    delete_marker_replication {
      status = "Enabled"
    }

    destination {
      bucket        = aws_s3_bucket.crr.arn
      storage_class = "STANDARD"
    }
  }

  rule {
    id       = "to-same-region"
    priority = 2
    status   = "Enabled"

    filter {}

    delete_marker_replication {
      status = "Enabled"
    }

    destination {
      bucket        = aws_s3_bucket.srr.arn
      storage_class = "STANDARD"
    }
  }
}

output "bucket_name" {
  value = aws_s3_bucket.this.id
}

output "bucket_arn" {
  value = aws_s3_bucket.this.arn
}

output "replica_crr_bucket" {
  value = "${aws_s3_bucket.crr.id} (${var.replica_region})"
}

output "replica_srr_bucket" {
  value = "${aws_s3_bucket.srr.id} (${var.region})"
}

output "object_lock" {
  value = "${var.lock_mode}, ${var.lock_retention_days} day(s) default retention on all three buckets"
}

output "test_commands" {
  description = "Upload an object, then check it arrived (with its lock) in both replicas."
  value = join("\n", [
    "echo hello > test.txt",
    "aws s3api put-object --bucket ${aws_s3_bucket.this.id} --key test.txt --body test.txt --region ${var.region}",
    "# Wait ~1 minute, then. Status goes PENDING -> COMPLETED:",
    "aws s3api head-object --bucket ${aws_s3_bucket.this.id} --key test.txt --query ReplicationStatus --region ${var.region}",
    "aws s3api head-object --bucket ${aws_s3_bucket.crr.id} --key test.txt --query '[ObjectLockMode,ObjectLockRetainUntilDate]' --region ${var.replica_region}",
    "aws s3api head-object --bucket ${aws_s3_bucket.srr.id} --key test.txt --query '[ObjectLockMode,ObjectLockRetainUntilDate]' --region ${var.region}",
  ])
}

output "cost_estimate" {
  description = "Approximate us-east-1 list prices, no free tier applied."
  value = join("\n", [
    "Creation:         $0.00 (3 buckets, versioning, object lock, replication rules, IAM role are free)",
    "Per hour, empty:  $0.00",
    "Per hour, 1 GB:   ~$0.000095 (~$0.069/month: 3 S3 copies x $0.023 per GB-month)",
    "Other:            PUT/COPY requests $0.005 per 1,000",
    "                  CRR transfer ~$0.02 per GB replicated (one-time per GB)",
  ])
}
