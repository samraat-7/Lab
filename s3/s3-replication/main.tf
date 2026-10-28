# S3 replication demo: one source bucket, two destinations.
#
#   source  (us-east-1)  --CRR-->  replica-crr  (us-west-2)   different region
#           (us-east-1)  --SRR-->  replica-srr  (us-east-1)   same region
#
# All three buckets have S3 Object Lock with a default retention of 3 days in
# GOVERNANCE mode. S3 requires Object Lock on the destinations to replicate
# locked objects, and replicas keep the source object's retention.
# GOVERNANCE is deliberate: force_destroy bypasses it, so `terraform destroy` /
# down.sh still works. COMPLIANCE would block destroy until retention passes.
#
# Runs with no edits. Empty buckets cost nothing; see Cost below.

# Cost (approx. us-east-1 list prices, no free tier applied):
#   Creation:         $0.00 (3 buckets, versioning, SSE-S3, object lock, replication rules, IAM role are free)
#   Per hour, empty:  $0.00
#   Per hour, 1 GB:   ~$0.000095 (~$0.069/month: 3 S3 copies x $0.023 per GB-month)
#   Other:            PUT/COPY requests $0.005 per 1,000
#                     CRR transfer ~$0.02 per GB replicated (one-time per GB)
#                     locked versions are billed for at least 3 days, in all 3 buckets

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

variable "primary_region" {
  description = "Region of the source bucket and the same-region replica"
  type        = string
  default     = "us-east-1"
}

variable "replica_region" {
  description = "Region of the cross-region replica. Must differ from primary_region."
  type        = string
  default     = "us-west-2"

  validation {
    condition     = var.replica_region != var.primary_region
    error_message = "replica_region must be a different region from primary_region, otherwise it is not cross-region."
  }
}

variable "name_prefix" {
  description = "Prefix for every bucket and role name (lowercase letters, numbers, hyphens)"
  type        = string
  default     = "ft-repl"
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
  default     = 3
}

provider "aws" {
  region = var.primary_region
}

provider "aws" {
  alias  = "replica"
  region = var.replica_region
}

# Bucket names are global, so a random suffix avoids "name already taken".
resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  sfx = random_id.suffix.hex

  source_name = "${var.name_prefix}-source-${local.sfx}"
  crr_name    = "${var.name_prefix}-crr-${var.replica_region}-${local.sfx}"
  srr_name    = "${var.name_prefix}-srr-${var.primary_region}-${local.sfx}"
}

# ---------------------------------------------------------------------------
# Source bucket (primary region)
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "source" {
  bucket              = local.source_name
  object_lock_enabled = true
  force_destroy       = true # lets terraform destroy remove a bucket that has objects

  tags = {
    Name = local.source_name
    Role = "replication-source"
  }
}

resource "aws_s3_bucket_versioning" "source" {
  bucket = aws_s3_bucket.source.id

  versioning_configuration {
    status = "Enabled" # replication will not work without this
  }
}

resource "aws_s3_bucket_public_access_block" "source" {
  bucket                  = aws_s3_bucket.source.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "source" {
  bucket = aws_s3_bucket.source.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_object_lock_configuration" "source" {
  bucket = aws_s3_bucket.source.id

  rule {
    default_retention {
      mode = var.lock_mode
      days = var.lock_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.source]
}

# ---------------------------------------------------------------------------
# Destination 1: cross-region (CRR)
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "crr" {
  provider = aws.replica

  bucket              = local.crr_name
  object_lock_enabled = true
  force_destroy       = true

  tags = {
    Name = local.crr_name
    Role = "replication-target-cross-region"
  }
}

resource "aws_s3_bucket_versioning" "crr" {
  provider = aws.replica

  bucket = aws_s3_bucket.crr.id

  versioning_configuration {
    status = "Enabled" # destination must be versioned too
  }
}

resource "aws_s3_bucket_public_access_block" "crr" {
  provider = aws.replica

  bucket                  = aws_s3_bucket.crr.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "crr" {
  provider = aws.replica

  bucket = aws_s3_bucket.crr.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
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
# Destination 2: same-region (SRR)
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "srr" {
  bucket              = local.srr_name
  object_lock_enabled = true
  force_destroy       = true

  tags = {
    Name = local.srr_name
    Role = "replication-target-same-region"
  }
}

resource "aws_s3_bucket_versioning" "srr" {
  bucket = aws_s3_bucket.srr.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "srr" {
  bucket                  = aws_s3_bucket.srr.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "srr" {
  bucket = aws_s3_bucket.srr.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
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
  name               = "${var.name_prefix}-replication-${local.sfx}"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "replication" {
  # Read the replication rules and list the source bucket
  statement {
    actions   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
    resources = [aws_s3_bucket.source.arn]
  }

  # Read each object version from the source
  statement {
    actions = [
      "s3:GetObjectVersionForReplication",
      "s3:GetObjectVersionAcl",
      "s3:GetObjectVersionTagging",
      "s3:GetObjectRetention", # needed to replicate Object Lock settings
      "s3:GetObjectLegalHold",
    ]
    resources = ["${aws_s3_bucket.source.arn}/*"]
  }

  # Write into BOTH destinations
  statement {
    actions = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"]
    resources = [
      "${aws_s3_bucket.crr.arn}/*",
      "${aws_s3_bucket.srr.arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "replication" {
  name   = "${var.name_prefix}-replication"
  role   = aws_iam_role.replication.id
  policy = data.aws_iam_policy_document.replication.json
}

# ---------------------------------------------------------------------------
# The replication rules (on the SOURCE bucket)
#
# Two destinations means two rules. With more than one rule, each needs a
# unique priority and a filter. An empty filter {} means "every object".
# ---------------------------------------------------------------------------

resource "aws_s3_bucket_replication_configuration" "source" {
  # Replication refuses to save until versioning is on at both ends, and the
  # role must have its permissions before S3 tries to use it.
  depends_on = [
    aws_s3_bucket_versioning.source,
    aws_s3_bucket_versioning.crr,
    aws_s3_bucket_versioning.srr,
    aws_s3_bucket_object_lock_configuration.source,
    aws_s3_bucket_object_lock_configuration.crr,
    aws_s3_bucket_object_lock_configuration.srr,
    aws_iam_role_policy.replication,
  ]

  bucket = aws_s3_bucket.source.id
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

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "source_bucket" {
  value = aws_s3_bucket.source.id
}

output "cross_region_bucket" {
  value = aws_s3_bucket.crr.id
}

output "same_region_bucket" {
  value = aws_s3_bucket.srr.id
}

output "object_lock" {
  value = "${var.lock_mode}, ${var.lock_retention_days} day(s) default retention on all three buckets"
}

output "test_commands" {
  description = "Paste these into PowerShell after apply."
  value = join("\n", [
    "'hello' | Set-Content test.txt",
    "aws s3 cp test.txt s3://${aws_s3_bucket.source.id}/test.txt",
    "aws s3api head-object --bucket ${aws_s3_bucket.source.id} --key test.txt --query ReplicationStatus",
    "aws s3 ls s3://${aws_s3_bucket.srr.id}/",
    "aws s3 ls s3://${aws_s3_bucket.crr.id}/ --region ${var.replica_region}",
    "aws s3api head-object --bucket ${aws_s3_bucket.srr.id} --key test.txt --query '[ObjectLockMode,ObjectLockRetainUntilDate]'",
    "aws s3api head-object --bucket ${aws_s3_bucket.crr.id} --key test.txt --query '[ObjectLockMode,ObjectLockRetainUntilDate]' --region ${var.replica_region}",
  ])
}

output "cost_estimate" {
  description = "Approximate us-east-1 list prices, no free tier applied."
  value = join("\n", [
    "Creation:         $0.00 (3 buckets, versioning, SSE-S3, object lock, replication rules, IAM role are free)",
    "Per hour, empty:  $0.00",
    "Per hour, 1 GB:   ~$0.000095 (~$0.069/month: 3 S3 copies x $0.023 per GB-month)",
    "Other:            PUT/COPY requests $0.005 per 1,000",
    "                  CRR transfer ~$0.02 per GB replicated (one-time per GB)",
    "                  locked versions are billed for at least 3 days, in all 3 buckets",
  ])
}
