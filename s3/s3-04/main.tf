# s3-04 — cross-region replication (CRR)
#
#   s3-04 (us-east-1) --CRR--> s3-04-replica (us-west-2)
#
# Versioning is required on both buckets. Only objects written after apply are
# replicated.
# Posture expectation: copy_count 1, geo_separation > 0 (replica is in another
# region), immutable_status 0.
# Free tier: empty buckets are free; each replicated GB pays ~$0.02 transfer
# plus storage in both regions, so keep objects tiny.

# Cost (approx. us-east-1 list prices, no free tier applied):
#   Creation:         $0.00 (2 buckets, versioning, replication rule, IAM role are free)
#   Per hour, empty:  $0.00
#   Per hour, 1 GB:   ~$0.000063 (~$0.046/month: 2 S3 copies x $0.023 per GB-month)
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
  description = "Region of the source bucket"
  type        = string
  default     = "us-east-1"
}

variable "replica_region" {
  description = "Region of the replica bucket. Must differ from region."
  type        = string
  default     = "us-west-2"

  validation {
    condition     = var.replica_region != var.region
    error_message = "replica_region must differ from region, otherwise it is not cross-region."
  }
}

variable "name_prefix" {
  description = "Prefix for the bucket name"
  type        = string
  default     = "ft-posture"
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

# ---------------------------------------------------------------------------
# Source bucket
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "this" {
  bucket        = "${var.name_prefix}-s3-04-${local.account_id}"
  force_destroy = true

  tags = {
    Name       = "s3-04"
    Fixture    = "posture-test"
    Protection = "replication-cross-region"
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

# ---------------------------------------------------------------------------
# Replica bucket (other region)
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "replica" {
  provider = aws.replica

  bucket        = "${var.name_prefix}-s3-04-replica-${local.account_id}"
  force_destroy = true

  tags = {
    Name       = "s3-04-replica"
    Fixture    = "posture-test"
    Protection = "replication-target-cross-region"
    FreeTier   = "true"
  }
}

resource "aws_s3_bucket_public_access_block" "replica" {
  provider = aws.replica

  bucket = aws_s3_bucket.replica.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "replica" {
  provider = aws.replica

  bucket = aws_s3_bucket.replica.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ---------------------------------------------------------------------------
# IAM role S3 assumes to copy objects
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
  name               = "${var.name_prefix}-s3-04-replication"
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
    ]
    resources = ["${aws_s3_bucket.this.arn}/*"]
  }

  statement {
    actions   = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"]
    resources = ["${aws_s3_bucket.replica.arn}/*"]
  }
}

resource "aws_iam_role_policy" "replication" {
  name   = "${var.name_prefix}-s3-04-replication"
  role   = aws_iam_role.replication.id
  policy = data.aws_iam_policy_document.replication.json
}

# ---------------------------------------------------------------------------
# Replication rule (on the source bucket)
# ---------------------------------------------------------------------------

resource "aws_s3_bucket_replication_configuration" "this" {
  depends_on = [
    aws_s3_bucket_versioning.this,
    aws_s3_bucket_versioning.replica,
    aws_iam_role_policy.replication,
  ]

  bucket = aws_s3_bucket.this.id
  role   = aws_iam_role.replication.arn

  rule {
    id     = "to-other-region"
    status = "Enabled"

    filter {}

    delete_marker_replication {
      status = "Enabled"
    }

    destination {
      bucket        = aws_s3_bucket.replica.arn
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

output "replica_bucket_name" {
  value = aws_s3_bucket.replica.id
}

output "replica_region" {
  value = var.replica_region
}

output "cost_estimate" {
  description = "Approximate us-east-1 list prices, no free tier applied."
  value = join("\n", [
    "Creation:         $0.00 (2 buckets, versioning, replication rule, IAM role are free)",
    "Per hour, empty:  $0.00",
    "Per hour, 1 GB:   ~$0.000063 (~$0.046/month: 2 S3 copies x $0.023 per GB-month)",
    "Other:            PUT/COPY requests $0.005 per 1,000",
    "                  CRR transfer ~$0.02 per GB replicated (one-time per GB)",
  ])
}
