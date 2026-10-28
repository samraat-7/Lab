# S3 bucket + AWS Backup + cross-region copy to a DR vault + Vault Lock
#
#   bucket (us-east-1) --daily backup--> primary vault (us-east-1)
#                                                    |
#                                                    +--copy--> DR vault (us-west-2)
#
# Only the DR vault gets a Vault Lock (COMPLIANCE mode, 3-day grace period).
# The primary vault is not locked.
#
# READ THIS BEFORE APPLYING
#   For the first 3 days (the grace period, lock_grace_days) the lock can still be removed.
#   After that it is permanent: nobody, including the root user and AWS, can
#   remove it or shorten retention. A locked vault cannot be deleted while it
#   holds recovery points, so `terraform destroy` fails until they expire.
#   Retention here is 7 days, so cleanup takes at most 7 days after the last
#   backup. Set enable_vault_lock = false to skip the lock entirely.

# Cost (approx. us-east-1 list prices, no free tier applied):
#   Creation:         $0.00 (bucket, versioning, SSE-S3, 2 vaults, 1 vault lock (DR), backup plan, IAM role are free)
#   Per hour, empty:  $0.00
#   Per hour, 1 GB:   ~$0.000168 (~$0.123/month: 1 S3 copy x $0.023 + 2 vault copies x $0.05 per GB-month)
#   Other:            PUT/COPY requests $0.005 per 1,000
#                     cross-region copy ~$0.02 per GB per copy job
#   AWS Backup breakdown (per 1 GB of bucket data; an empty bucket costs $0.00)
#     Backs up: bucket ARN, daily 05:00 UTC, kept 7 days, DR vault locked
#     Backup job, same region (primary vault): $0.00 per job
#       + S3 requests the job makes: GET $0.004 / 10k, LIST $0.05 / 10k (fractions of a cent)
#     Primary vault storage : $0.05/GB-mo = ~$0.05/month ($0.00007/hr) per GB
#       objects under 128 KB are billed as 128 KB
#     Copy job to DR vault  : $0.00 per job
#     Copy transfer         : $0.02/GB cross-region - full on the first copy, incremental after
#     DR vault storage      : $0.05/GB-mo = ~$0.05/month ($0.00007/hr) per GB
#     Backup total          : ~$0.10/month per GB + ~$0.02 per GB for the first copy
#     Restore               : $0.02/GB restored + PUT $0.05 / 10k objects

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

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

variable "primary_region" {
  type    = string
  default = "us-east-1"
}

variable "dr_region" {
  description = "Region of the DR vault. Must differ from primary_region."
  type        = string
  default     = "us-west-2"

  validation {
    condition     = var.dr_region != var.primary_region
    error_message = "dr_region must be a different region from primary_region."
  }
}

variable "name_prefix" {
  type    = string
  default = "ft-s3bkp"
}

variable "retention_days" {
  description = "How long recovery points are kept, in both vaults"
  type        = number
  default     = 7
}

variable "enable_vault_lock" {
  description = "Apply Vault Lock (compliance mode) to the DR vault"
  type        = bool
  default     = true
}

variable "lock_grace_days" {
  description = "Grace period before the lock becomes permanent. AWS minimum is 3."
  type        = number
  default     = 3

  validation {
    condition     = var.lock_grace_days >= 3 && var.lock_grace_days <= 36500
    error_message = "lock_grace_days must be at least 3 (AWS minimum)."
  }
}

variable "lock_min_retention_days" {
  description = "Vault Lock: shortest retention any backup into the vault may have"
  type        = number
  default     = 1
}

variable "lock_max_retention_days" {
  description = "Vault Lock: longest retention any backup into the vault may have"
  type        = number
  default     = 7
}

# ---------------------------------------------------------------------------
# Providers
# ---------------------------------------------------------------------------

provider "aws" {
  region = var.primary_region
}

provider "aws" {
  alias  = "dr"
  region = var.dr_region
}

resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  sfx         = random_id.suffix.hex
  bucket_name = "${var.name_prefix}-data-${local.sfx}"

  # The lock rejects any backup whose retention is outside this range, so fail
  # at plan time instead of at the first backup.
  retention_ok = (
    var.retention_days >= var.lock_min_retention_days &&
    var.retention_days <= var.lock_max_retention_days
  )
}

# ---------------------------------------------------------------------------
# The bucket being protected
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "data" {
  bucket        = local.bucket_name
  force_destroy = true

  tags = {
    Name = local.bucket_name
    Role = "backup-source"
  }

  lifecycle {
    precondition {
      condition     = local.retention_ok
      error_message = "retention_days must sit between lock_min_retention_days and lock_max_retention_days, or the vault lock will reject every backup."
    }
  }
}

# AWS Backup cannot protect an S3 bucket without versioning.
resource "aws_s3_bucket_versioning" "data" {
  bucket = aws_s3_bucket.data.id

  versioning_configuration {
    status = "Enabled"
  }
}



resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ---------------------------------------------------------------------------
# Vaults: primary and DR
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

resource "aws_backup_vault" "primary" {
  name          = "${var.name_prefix}-vault-${local.sfx}"
  force_destroy = true # allows deleting a vault that still holds recovery points

  tags = {
    Role = "primary-vault"
  }
}

resource "aws_backup_vault" "dr" {
  provider = aws.dr

  name          = "${var.name_prefix}-dr-vault-${local.sfx}"
  force_destroy = true

  tags = {
    Role = "dr-vault"
  }
}

# ---------------------------------------------------------------------------
# COPY JOB REQUIREMENTS (everything start-copy-job and the plan's copy_action need)
#   1. Service role passed as --iam-role-arn has
#      AWSBackupServiceRolePolicyForBackup + ForS3Backup + ForS3Restore.
#   2. Destination vault allows backup:CopyIntoBackupVault for this account
#      (vault access policy below).
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

data "aws_iam_policy_document" "dr_vault" {
  statement {
    sid       = "AllowCopyIntoFromThisAccount"
    actions   = ["backup:CopyIntoBackupVault"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_backup_vault_policy" "dr" {
  provider = aws.dr

  backup_vault_name = aws_backup_vault.dr.name
  policy            = data.aws_iam_policy_document.dr_vault.json
}

# ---------------------------------------------------------------------------
# IAM role AWS Backup uses. S3 has its OWN managed policies, separate from the
# EC2/EBS ones, and the generic policy does not cover S3.
# ---------------------------------------------------------------------------

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
  name               = "${var.name_prefix}-backup-${local.sfx}"
  assume_role_policy = data.aws_iam_policy_document.backup_assume.json
}

# Generic AWS Backup permissions; copy jobs into the DR vault need these.
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

# ---------------------------------------------------------------------------
# Backup plan: daily at 05:00 UTC, kept 7 days, copied to the DR vault
# ---------------------------------------------------------------------------

resource "aws_backup_plan" "s3" {
  name = "${var.name_prefix}-plan-${local.sfx}"

  rule {
    rule_name         = "daily-with-dr-copy"
    target_vault_name = aws_backup_vault.primary.name
    schedule          = "cron(0 5 * * ? *)"
    start_window      = 60
    completion_window = 360

    lifecycle {
      delete_after = var.retention_days
    }

    copy_action {
      destination_vault_arn = aws_backup_vault.dr.arn

      lifecycle {
        delete_after = var.retention_days
      }
    }
  }
}

resource "aws_backup_selection" "s3" {
  name         = "${var.name_prefix}-selection"
  plan_id      = aws_backup_plan.s3.id
  iam_role_arn = aws_iam_role.backup.arn

  resources = [aws_s3_bucket.data.arn]

  depends_on = [
    aws_s3_bucket_versioning.data,
    aws_iam_role_policy_attachment.backup,
    aws_iam_role_policy_attachment.s3_backup,
    aws_iam_role_policy_attachment.s3_restore,
  ]
}

# ---------------------------------------------------------------------------
# Vault Lock, compliance mode. changeable_for_days is what makes it compliance
# mode: leave it out and the lock is governance mode, which can always be
# removed. The grace days start the moment the lock is created.
#
# Created after the plan so the plan's retention is already known to be valid.
# ---------------------------------------------------------------------------

resource "aws_backup_vault_lock_configuration" "dr" {
  count    = var.enable_vault_lock ? 1 : 0
  provider = aws.dr

  backup_vault_name   = aws_backup_vault.dr.name
  changeable_for_days = var.lock_grace_days
  min_retention_days  = var.lock_min_retention_days
  max_retention_days  = var.lock_max_retention_days

  depends_on = [aws_backup_plan.s3]
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "bucket" {
  value = aws_s3_bucket.data.id
}

output "primary_vault" {
  value = aws_backup_vault.primary.name
}

output "dr_vault" {
  value = aws_backup_vault.dr.name
}

output "backup_role_arn" {
  value = aws_iam_role.backup.arn
}

output "lock_grace_ends" {
  description = "Cancel the lock before this point if you change your mind."
  value       = var.enable_vault_lock ? "${var.lock_grace_days} days after apply" : "no lock applied"
}

output "next_steps" {
  description = "Run the first backup now instead of waiting for 05:00 UTC."
  value = join("\n", [
    "# 0. Once per account and region: AWS Backup > Settings > Service opt-in > enable S3 (and in ${var.dr_region}). Without it nothing backs up.",
    "# 1. Upload something:",
    "'hello' | Set-Content test.txt; aws s3 cp test.txt s3://${aws_s3_bucket.data.id}/test.txt",
    "# 2. Back up now:",
    "aws backup start-backup-job --backup-vault-name ${aws_backup_vault.primary.name} --resource-arn ${aws_s3_bucket.data.arn} --iam-role-arn ${aws_iam_role.backup.arn} --lifecycle DeleteAfterDays=${var.retention_days}",
    "# 3. When that job is COMPLETED, find the recovery point:",
    "aws backup list-recovery-points-by-backup-vault --backup-vault-name ${aws_backup_vault.primary.name} --query 'RecoveryPoints[].RecoveryPointArn'",
    "# 4. Copy it to the DR vault now:",
    "aws backup start-copy-job --recovery-point-arn <arn-from-step-3> --source-backup-vault-name ${aws_backup_vault.primary.name} --destination-backup-vault-arn ${aws_backup_vault.dr.arn} --iam-role-arn ${aws_iam_role.backup.arn} --lifecycle DeleteAfterDays=${var.retention_days}",
  ])
}

output "cost_estimate" {
  description = "Approximate us-east-1 list prices, no free tier applied."
  value = join("\n", [
    "Creation:         $0.00 (bucket, versioning, SSE-S3, 2 vaults, 1 vault lock (DR), backup plan, IAM role are free)",
    "Per hour, empty:  $0.00",
    "Per hour, 1 GB:   ~$0.000168 (~$0.123/month: 1 S3 copy x $0.023 + 2 vault copies x $0.05 per GB-month)",
    "Other:            PUT/COPY requests $0.005 per 1,000",
    "                  cross-region copy ~$0.02 per GB per copy job",
    "AWS Backup breakdown (per 1 GB of bucket data; an empty bucket costs $0.00)",
    "  Backs up: bucket ARN, daily 05:00 UTC, kept 7 days, DR vault locked",
    "  Backup job, same region (primary vault): $0.00 per job",
    "    + S3 requests the job makes: GET $0.004 / 10k, LIST $0.05 / 10k (fractions of a cent)",
    "  Primary vault storage : $0.05/GB-mo = ~$0.05/month ($0.00007/hr) per GB",
    "    objects under 128 KB are billed as 128 KB",
    "  Copy job to DR vault  : $0.00 per job",
    "  Copy transfer         : $0.02/GB cross-region - full on the first copy, incremental after",
    "  DR vault storage      : $0.05/GB-mo = ~$0.05/month ($0.00007/hr) per GB",
    "  Backup total          : ~$0.10/month per GB + ~$0.02 per GB for the first copy",
    "  Restore               : $0.02/GB restored + PUT $0.05 / 10k objects",
  ])
}

output "copy_job_requirements" {
  description = "Everything an AWS Backup copy job from this folder needs."
  value = join("\n", [
    "1. Service role: ${aws_iam_role.backup.arn}",
    "   policies: ${join(", ", [aws_iam_role_policy_attachment.backup.policy_arn, aws_iam_role_policy_attachment.s3_backup.policy_arn, aws_iam_role_policy_attachment.s3_restore.policy_arn])}",
    "2. DR vault access policy: backup:CopyIntoBackupVault allowed on ${aws_backup_vault.dr.name} (${var.dr_region})",
    "3. Service opt-in: S3 ON in ${var.primary_region} and ${var.dr_region}",
    "4. Run start-copy-job in ${var.primary_region} after the backup job is COMPLETED",
    "5. --lifecycle DeleteAfterDays must fit the locked vault's min/max retention",
    "6. Your CLI user: backup:StartCopyJob, backup:DescribeCopyJob, iam:PassRole on ${aws_iam_role.backup.name}",
    "7. Default KMS keys only, so no extra KMS grants needed",
  ])
}
