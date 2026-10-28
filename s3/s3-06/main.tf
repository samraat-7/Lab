# s3-06 — AWS Backup plan with cross-region copy to a DR vault
#
#   s3-06 (us-east-1) --weekly backup--> s3-06 vault (us-east-1)
#                                               |
#                                               +--copy--> s3-06 DR vault (us-west-2)
#
# Pair of s3-05; differs by a weekly schedule and a copy_action into a vault in
# a second region. No Vault Lock, so everything can be destroyed freely.
# Posture expectation: copy_count 2, geo_separation > 0, immutable_status 0.
#
# ONE MANUAL STEP: AWS Backup > Settings > Service opt-in > enable S3 in BOTH
# regions. Without it the plan is created but backs up nothing, with no error.
# Free tier: AWS Backup for S3 is not free; ~$0.05/GB-month per vault plus
# ~$0.02/GB for each cross-region copy. Keep the bucket near empty.

# Cost (approx. us-east-1 list prices, no free tier applied):
#   Creation:         $0.00 (bucket, versioning, SSE-S3, 2 vaults, backup plan, IAM role are free)
#   Per hour, empty:  $0.00
#   Per hour, 1 GB:   ~$0.000168 (~$0.123/month: 1 S3 copy x $0.023 + 2 vault copies x $0.05 per GB-month)
#   Other:            PUT/COPY requests $0.005 per 1,000
#                     cross-region copy ~$0.02 per GB per copy job
#   AWS Backup breakdown (per 1 GB of bucket data; an empty bucket costs $0.00)
#     Backs up: bucket ARN, weekly, Sunday 05:00 UTC, kept 14 days, no vault lock
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
  }
}

provider "aws" {
  region = var.region
}

provider "aws" {
  alias  = "dr"
  region = var.dr_region
}

variable "region" {
  description = "Region of the bucket and primary vault"
  type        = string
  default     = "us-east-1"
}

variable "dr_region" {
  description = "Region of the DR vault. Must differ from region."
  type        = string
  default     = "us-west-2"

  validation {
    condition     = var.dr_region != var.region
    error_message = "dr_region must differ from region."
  }
}

variable "name_prefix" {
  description = "Prefix for the bucket name"
  type        = string
  default     = "ft-posture"
}

variable "backup_retention_days" {
  description = "Days AWS Backup keeps each recovery point, in both vaults"
  type        = number
  default     = 14
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Bucket being protected
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "this" {
  bucket        = "${var.name_prefix}-s3-06-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name       = "s3-06"
    Fixture    = "posture-test"
    Protection = "aws-backup-cross-region-copy"
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

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ---------------------------------------------------------------------------
# Vaults: primary and DR
# ---------------------------------------------------------------------------

resource "aws_backup_vault" "primary" {
  name          = "${var.name_prefix}-s3-06-vault"
  force_destroy = true

  tags = {
    Fixture = "posture-test"
  }
}

resource "aws_backup_vault" "dr" {
  provider = aws.dr

  name          = "${var.name_prefix}-s3-06-dr-vault"
  force_destroy = true

  tags = {
    Fixture = "posture-test"
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
# IAM role, plan, selection
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
  name               = "${var.name_prefix}-s3-06-backup"
  assume_role_policy = data.aws_iam_policy_document.backup_assume.json
}

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
  name = "${var.name_prefix}-s3-06-plan"

  rule {
    rule_name         = "weekly-with-dr-copy"
    target_vault_name = aws_backup_vault.primary.name
    schedule          = "cron(0 5 ? * SUN *)"
    start_window      = 60
    completion_window = 360

    lifecycle {
      delete_after = var.backup_retention_days
    }

    copy_action {
      destination_vault_arn = aws_backup_vault.dr.arn

      lifecycle {
        delete_after = var.backup_retention_days
      }
    }
  }
}

resource "aws_backup_selection" "this" {
  name         = "${var.name_prefix}-s3-06-selection"
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

output "primary_vault" {
  value = aws_backup_vault.primary.name
}

output "dr_vault" {
  value = aws_backup_vault.dr.name
}

output "backup_now" {
  description = "Run the first backup now instead of waiting for Sunday 05:00 UTC."
  value       = "aws backup start-backup-job --backup-vault-name ${aws_backup_vault.primary.name} --resource-arn ${aws_s3_bucket.this.arn} --iam-role-arn ${aws_iam_role.backup.arn} --lifecycle DeleteAfterDays=${var.backup_retention_days}"
}

output "copy_now" {
  description = "Copy a COMPLETED recovery point to the DR vault now, then check it."
  value = join("\n", [
    "aws backup list-recovery-points-by-backup-vault --backup-vault-name ${aws_backup_vault.primary.name} --query 'RecoveryPoints[].[RecoveryPointArn,Status]' --region ${var.region}",
    "aws backup start-copy-job --recovery-point-arn <recovery-point-arn> --source-backup-vault-name ${aws_backup_vault.primary.name} --destination-backup-vault-arn ${aws_backup_vault.dr.arn} --iam-role-arn ${aws_iam_role.backup.arn} --lifecycle DeleteAfterDays=${var.backup_retention_days} --region ${var.region} --query CopyJobId --output text",
    "aws backup describe-copy-job --copy-job-id <copy-job-id> --query 'CopyJob.[State,StatusMessage]' --region ${var.region}",
    "aws backup list-recovery-points-by-backup-vault --backup-vault-name ${aws_backup_vault.dr.name} --region ${var.dr_region}",
  ])
}

output "cost_estimate" {
  description = "Approximate us-east-1 list prices, no free tier applied."
  value = join("\n", [
    "Creation:         $0.00 (bucket, versioning, SSE-S3, 2 vaults, backup plan, IAM role are free)",
    "Per hour, empty:  $0.00",
    "Per hour, 1 GB:   ~$0.000168 (~$0.123/month: 1 S3 copy x $0.023 + 2 vault copies x $0.05 per GB-month)",
    "Other:            PUT/COPY requests $0.005 per 1,000",
    "                  cross-region copy ~$0.02 per GB per copy job",
    "AWS Backup breakdown (per 1 GB of bucket data; an empty bucket costs $0.00)",
    "  Backs up: bucket ARN, weekly, Sunday 05:00 UTC, kept 14 days, no vault lock",
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
    "3. Service opt-in: S3 ON in ${var.region} and ${var.dr_region}",
    "4. Run start-copy-job in ${var.region} after the backup job is COMPLETED",
    "5. --lifecycle DeleteAfterDays must fit the locked vault's min/max retention",
    "6. Your CLI user: backup:StartCopyJob, backup:DescribeCopyJob, iam:PassRole on ${aws_iam_role.backup.name}",
    "7. Default KMS keys only, so no extra KMS grants needed",
  ])
}
