# s3-05 — AWS Backup plan, single-region vault
#
#   s3-05 (us-east-1) --daily backup--> s3-05 vault (us-east-1)
#
# AWS Backup requires versioning on the bucket. No Vault Lock, so the vault
# and its recovery points can be deleted freely.
# Posture expectation: copy_count 1 (a backup copy exists), geo_separation 0,
# immutable_status 0.
#
# ONE MANUAL STEP: AWS Backup > Settings > Service opt-in > enable S3 in this
# region. Without it the plan is created but backs up nothing, with no error.
# Free tier: AWS Backup for S3 is not free; an empty or tiny bucket costs
# fractions of a cent (~$0.05/GB-month in the vault).

# Cost (approx. us-east-1 list prices, no free tier applied):
#   Creation:         $0.00 (bucket, versioning, vault, backup plan, IAM role are free)
#   Per hour, empty:  $0.00
#   Per hour, 1 GB:   ~$0.0001 (~$0.073/month: 1 S3 copy x $0.023 + 1 vault copy x $0.05 per GB-month)
#   Other:            PUT/COPY requests $0.005 per 1,000
#                     each backup job also makes S3 GET/LIST requests (fractions of a cent)
#   AWS Backup breakdown (per 1 GB of bucket data; an empty bucket costs $0.00)
#     Backs up: bucket ARN, daily 05:00 UTC, kept 7 days, no vault lock
#     Backup job, same region (primary vault): $0.00 per job
#       + S3 requests the job makes: GET $0.004 / 10k, LIST $0.05 / 10k (fractions of a cent)
#     Primary vault storage : $0.05/GB-mo = ~$0.05/month ($0.00007/hr) per GB
#       objects under 128 KB are billed as 128 KB
#     Copy job              : none in this stack
#     Backup total          : ~$0.05/month per GB
#     Restore               : $0.02/GB restored + PUT $0.05 / 10k objects

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

variable "backup_retention_days" {
  description = "Days AWS Backup keeps each recovery point"
  type        = number
  default     = 7
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Bucket being protected
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "this" {
  bucket        = "${var.name_prefix}-s3-05-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name       = "s3-05"
    Fixture    = "posture-test"
    Protection = "aws-backup"
    FreeTier   = "false"
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
# Vault, IAM role, plan, selection
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# COPY JOB REQUIREMENTS (everything start-copy-job and the plan's copy_action need)
#   1. Service role passed as --iam-role-arn has
#      AWSBackupServiceRolePolicyForBackup + ForS3Backup + ForS3Restore.
#   2. Destination vault allows backup:CopyIntoBackupVault for this account
#      (vault access policy; this folder has no DR vault).
#   3. AWS Backup > Settings > Service opt-in: S3 ON in the source AND the
#      destination region.
#   4. The source recovery point is COMPLETED; run start-copy-job in the
#      SOURCE region.
#   5. --lifecycle DeleteAfterDays sits inside a locked vault's min/max
#      retention, otherwise the copy is rejected.
#   6. The CLI user running the copy has backup:StartCopyJob,
#      backup:DescribeCopyJob and iam:PassRole on the service role.
#   7. Encryption: vaults use the default aws/backup KMS key and the bucket uses SSE-S3,
#      so no extra KMS grants are needed. A customer-managed key would need a
#      key policy allowing the service role in both regions.
# ---------------------------------------------------------------------------

resource "aws_backup_vault" "this" {
  name          = "${var.name_prefix}-s3-05-vault"
  force_destroy = true

  tags = {
    Fixture = "posture-test"
  }
}

data "aws_iam_policy_document" "backup_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  name               = "${var.name_prefix}-s3-05-backup"
  assume_role_policy = data.aws_iam_policy_document.backup_assume.json
}

# S3 has its own managed policies; the generic backup policy does not cover S3.
# Generic AWS Backup permissions; copy jobs need these on top of the S3 ones.
resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "s3_backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/AWSBackupServiceRolePolicyForS3Backup"
}

resource "aws_iam_role_policy_attachment" "s3_restore" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/AWSBackupServiceRolePolicyForS3Restore"
}

resource "aws_backup_plan" "this" {
  name = "${var.name_prefix}-s3-05-plan"

  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.this.name
    schedule          = "cron(0 5 * * ? *)"
    start_window      = 60
    completion_window = 360

    lifecycle {
      delete_after = var.backup_retention_days
    }
  }
}

resource "aws_backup_selection" "this" {
  name         = "${var.name_prefix}-s3-05-selection"
  plan_id      = aws_backup_plan.this.id
  iam_role_arn = aws_iam_role.backup.arn

  resources = [aws_s3_bucket.this.arn]

  depends_on = [
    aws_s3_bucket_versioning.this,
    aws_iam_role_policy_attachment.backup,
    aws_iam_role_policy_attachment.s3_backup,
    aws_iam_role_policy_attachment.s3_restore,
  ]
}

output "bucket_name" {
  value = aws_s3_bucket.this.id
}

output "bucket_arn" {
  value = aws_s3_bucket.this.arn
}

output "backup_vault" {
  value = aws_backup_vault.this.name
}

output "backup_now" {
  description = "Run the first backup now instead of waiting for 05:00 UTC."
  value       = "aws backup start-backup-job --backup-vault-name ${aws_backup_vault.this.name} --resource-arn ${aws_s3_bucket.this.arn} --iam-role-arn ${aws_iam_role.backup.arn} --lifecycle DeleteAfterDays=${var.backup_retention_days}"
}

output "cost_estimate" {
  description = "Approximate us-east-1 list prices, no free tier applied."
  value = join("\n", [
    "Creation:         $0.00 (bucket, versioning, vault, backup plan, IAM role are free)",
    "Per hour, empty:  $0.00",
    "Per hour, 1 GB:   ~$0.0001 (~$0.073/month: 1 S3 copy x $0.023 + 1 vault copy x $0.05 per GB-month)",
    "Other:            PUT/COPY requests $0.005 per 1,000",
    "                  each backup job also makes S3 GET/LIST requests (fractions of a cent)",
    "AWS Backup breakdown (per 1 GB of bucket data; an empty bucket costs $0.00)",
    "  Backs up: bucket ARN, daily 05:00 UTC, kept 7 days, no vault lock",
    "  Backup job, same region (primary vault): $0.00 per job",
    "    + S3 requests the job makes: GET $0.004 / 10k, LIST $0.05 / 10k (fractions of a cent)",
    "  Primary vault storage : $0.05/GB-mo = ~$0.05/month ($0.00007/hr) per GB",
    "    objects under 128 KB are billed as 128 KB",
    "  Copy job              : none in this stack",
    "  Backup total          : ~$0.05/month per GB",
    "  Restore               : $0.02/GB restored + PUT $0.05 / 10k objects",
  ])
}

output "copy_job_requirements" {
  description = "Everything an AWS Backup copy job from this folder needs."
  value = join("\n", [
    "1. Service role: ${aws_iam_role.backup.arn}",
    "   policies: ${join(", ", [aws_iam_role_policy_attachment.backup.policy_arn, aws_iam_role_policy_attachment.s3_backup.policy_arn, aws_iam_role_policy_attachment.s3_restore.policy_arn])}",
    "2. No DR vault in this folder; copy jobs need a destination vault (see s3-06 / s3-backup-dr).",
    "3. Service opt-in: S3 ON in ${var.region} and ${var.region}",
    "4. Run start-copy-job in ${var.region} after the backup job is COMPLETED",
    "5. --lifecycle DeleteAfterDays must fit the locked vault's min/max retention",
    "6. Your CLI user: backup:StartCopyJob, backup:DescribeCopyJob, iam:PassRole on ${aws_iam_role.backup.name}",
    "7. Default KMS keys only, so no extra KMS grants needed",
  ])
}
