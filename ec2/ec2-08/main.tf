# ec2-08 — instance + AWS Backup + copy job to a DR vault, ONE vault locked
#
#   instance (root vol)  --daily backup-->  primary vault (us-east-1)
#                                                  |
#                                                  +--copy job--> DR vault (us-west-2)
#
# The backup selection is the INSTANCE ARN, so each recovery point is an AMI
# covering the instance config and its root volume. Pairs with ec2-09, which
# backs up a VOLUME ARN instead.
#
# Only the DR vault is locked; the primary vault is not.
#
# VAULT LOCK MODES (var.lock_mode)
#   governance (default) - changeable_for_days is NOT set. The lock can be
#                          removed at any time by a principal with
#                          backup:DeleteBackupVaultLockConfiguration.
#   compliance           - changeable_for_days IS set. Removable only during
#                          the grace period, then permanent for everyone,
#                          root included. The vault cannot be deleted until
#                          every recovery point in it expires.
#
# ON-DEMAND BACKUP + COPY (manual - terraform apply does NOT run them)
#   The plan backs up and copies daily on its own. To do it now, run the
#   commands printed by: terraform output -raw commands
#   (see ON-DEMAND COMMANDS below for the same steps with placeholders).
#
# COST (us-east-1 on-demand list prices, before any free tier or credits)
#   Rates used: t3.micro $0.0104/hr | public IPv4 $0.005/hr | gp3 $0.08/GB-mo
#   ($0.00011/GB-hr) | snapshot / AWS Backup $0.05/GB-mo ($0.000068/GB-hr) |
#   cross-region copy transfer $0.02/GB. Vaults, plans, DLM, IAM, locks: free.
#   EC2 and EBS bill per second (60 s minimum); there is no creation fee.
#   One-time at creation : $0.02 (first DR copy moves 1 GB cross-region)
#   Per hour as deployed : $0.01141/hr  RUNNING: t3.micro (no public IP) + 8 GB gp3 + 1 GB recovery point in each vault
#   Per hour if stopped  : $0.00101/hr  (no compute or public IPv4; EBS, snapshots and backups still bill)
#   Per day / month      : ~$0.27/day | ~$8.33/month (as deployed)
#   TOTAL per hour       : $0.01141/hr as deployed (instance left running) | $0.00101/hr if you stop it
#   Stop the instance in the console to drop to ~$0.00101/hr.
#   AWS Backup breakdown - backs up: instance (root vol), kept 7 day(s)
#     Backup job, same region (primary vault): $0.00 per job
#     Primary vault storage : 1 GB x $0.05/GB-mo = $0.05/month ($0.00007/hr)
#     Copy job to DR vault  : $0.00 per job
#     Copy transfer         : $0.02/GB cross-region - first copy 1 GB = $0.02, later copies changed blocks only (<$0.01)
#     DR vault storage      : 1 GB x $0.05/GB-mo = $0.05/month ($0.00007/hr)
#     Backup total          : $0.10/month storage + $0.02 first copy
#     Restore (EC2/EBS)     : $0.00 - you pay only for the new instance/volume
#   Later daily copies are incremental: well under $0.01 each.
#
# BEFORE THE FIRST BACKUP
#   AWS Backup > Settings > Service opt-in: EC2 must be ON in both regions.
#   If it is off, jobs never run and nothing errors.
#
# ---------------------------------------------------------------------------
# ON-DEMAND COMMANDS (terraform output prints these with real values filled in)
# ---------------------------------------------------------------------------
#
# 1. On-demand backup job (run in the PRIMARY region):
#    aws backup start-backup-job \
#      --backup-vault-name <primary_vault_name> \
#      --resource-arn <instance_arn> \
#      --iam-role-arn <backup_role_arn> \
#      --lifecycle DeleteAfterDays=7 \
#      --region us-east-1
#    -> returns BackupJobId and RecoveryPointArn
#
# 2. Watch the backup job until State = COMPLETED:
#    aws backup describe-backup-job --backup-job-id <BackupJobId> --region us-east-1
#
# 3. List recovery points for the instance (newest first):
#    aws backup list-recovery-points-by-resource --resource-arn <instance_arn> --region us-east-1
#
# 4. On-demand copy job to the DR vault (run in the SOURCE region):
#    aws backup start-copy-job \
#      --recovery-point-arn <RecoveryPointArn> \
#      --source-backup-vault-name <primary_vault_name> \
#      --destination-backup-vault-arn <dr_vault_arn> \
#      --iam-role-arn <backup_role_arn> \
#      --lifecycle DeleteAfterDays=7 \
#      --region us-east-1
#    -> returns CopyJobId
#
# 5. Watch the copy job until State = COMPLETED:
#    aws backup describe-copy-job --copy-job-id <CopyJobId> --region us-east-1
#
# 6. Confirm the copy is in the DR vault:
#    aws backup list-recovery-points-by-backup-vault --backup-vault-name <dr_vault_name> --region us-west-2
#
# 7. Confirm which vault is locked:
#    aws backup describe-backup-vault --backup-vault-name <locked_vault_name> --region <locked_vault_region>
#
# 8. Remove the lock (governance: any time; compliance: grace period only):
#    aws backup delete-backup-vault-lock-configuration --backup-vault-name <locked_vault_name> --region <locked_vault_region>

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
  default = "ec2-08"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "root_volume_size" {
  description = "GiB. 8 is the Amazon Linux 2023 AMI minimum."
  type        = number
  default     = 8
}

variable "stop_instance" {
  description = "Stop the instance after creating it. Default false: it stays running. A stopped instance is still backed up."
  type        = bool
  default     = false
}

variable "retention_days" {
  description = "How long recovery points are kept, in both vaults"
  type        = number
  default     = 7
}

variable "lock_mode" {
  description = "\"governance\" (removable any time) or \"compliance\" (permanent after lock_grace_days)"
  type        = string
  default     = "governance"

  validation {
    condition     = contains(["governance", "compliance"], var.lock_mode)
    error_message = "lock_mode must be \"governance\" or \"compliance\"."
  }
}

variable "lock_grace_days" {
  description = "Compliance mode only: days before the lock becomes permanent. AWS minimum is 3."
  type        = number
  default     = 3

  validation {
    condition     = var.lock_grace_days >= 3
    error_message = "lock_grace_days must be at least 3 (AWS minimum)."
  }
}

variable "lock_min_retention_days" {
  type    = number
  default = 1
}

variable "lock_max_retention_days" {
  type    = number
  default = 365
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
  sfx = random_id.suffix.hex

  retention_ok = (
    var.retention_days >= var.lock_min_retention_days &&
    var.retention_days <= var.lock_max_retention_days
  )

  locked_vault_name   = aws_backup_vault.dr.name
  locked_vault_region = var.dr_region
}

# ---------------------------------------------------------------------------
# Network: default VPC, in an AZ that offers the instance type
# ---------------------------------------------------------------------------

data "aws_vpc" "default" {
  default = true
}

data "aws_ec2_instance_type_offerings" "supported" {
  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }

  location_type = "availability-zone"
}

data "aws_subnets" "usable" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "availability-zone"
    values = data.aws_ec2_instance_type_offerings.supported.locations
  }
}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_security_group" "this" {
  name        = "${var.name_prefix}-sg-${local.sfx}"
  description = "Egress only - no inbound"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-sg"
  }
}

# ---------------------------------------------------------------------------
# The instance
# ---------------------------------------------------------------------------

resource "aws_instance" "this" {
  ami                         = nonsensitive(data.aws_ssm_parameter.al2023.value)
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.usable.ids[0]
  vpc_security_group_ids      = [aws_security_group.this.id]
  associate_public_ip_address = false

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    delete_on_termination = true
    encrypted             = true

    tags = {
      Name = "${var.name_prefix}-root"
    }
  }

  tags = {
    Name = "${var.name_prefix}-instance"
  }

  lifecycle {
    precondition {
      condition     = length(data.aws_subnets.usable.ids) > 0
      error_message = "No default-VPC subnet in ${var.primary_region} offers ${var.instance_type}."
    }

    precondition {
      condition     = local.retention_ok
      error_message = "retention_days must sit between lock_min_retention_days and lock_max_retention_days, or the vault lock will reject backups."
    }
  }
}

resource "aws_ec2_instance_state" "this" {
  instance_id = aws_instance.this.id
  state       = var.stop_instance ? "stopped" : "running"
}

# ---------------------------------------------------------------------------
# Vaults: primary and DR
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

resource "aws_backup_vault" "primary" {
  name          = "${var.name_prefix}-vault-${local.sfx}"
  force_destroy = true

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
#      AWSBackupServiceRolePolicyForBackup + ForRestores.
#   2. Destination vault allows backup:CopyIntoBackupVault for this account
#      (vault access policy below).
#   3. AWS Backup > Settings > Service opt-in: EC2 ON in the source AND the
#      destination region.
#   4. The source recovery point is COMPLETED; run start-copy-job in the
#      SOURCE region.
#   5. --lifecycle DeleteAfterDays sits inside a locked vault's min/max
#      retention, otherwise the copy is rejected.
#   6. The CLI user running the copy has backup:StartCopyJob,
#      backup:DescribeCopyJob and iam:PassRole on the service role.
#   7. Encryption: vaults use the default aws/backup KMS key and EBS the default aws/ebs key,
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
# IAM role AWS Backup uses for backup, copy and restore
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

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "restore" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

# ---------------------------------------------------------------------------
# Backup plan: daily 05:00 UTC, copied to the DR vault
# ---------------------------------------------------------------------------

resource "aws_backup_plan" "this" {
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

resource "aws_backup_selection" "this" {
  name         = "${var.name_prefix}-selection"
  plan_id      = aws_backup_plan.this.id
  iam_role_arn = aws_iam_role.backup.arn

  resources = [aws_instance.this.arn]

  depends_on = [
    aws_iam_role_policy_attachment.backup,
    aws_iam_role_policy_attachment.restore,
  ]
}

# ---------------------------------------------------------------------------
# Vault Lock on the DR vault only. changeable_for_days = null means
# governance mode.
# ---------------------------------------------------------------------------

resource "aws_backup_vault_lock_configuration" "dr" {
  provider = aws.dr

  backup_vault_name   = aws_backup_vault.dr.name
  changeable_for_days = var.lock_mode == "compliance" ? var.lock_grace_days : null
  min_retention_days  = var.lock_min_retention_days
  max_retention_days  = var.lock_max_retention_days

  depends_on = [aws_backup_plan.this]
}

# ---------------------------------------------------------------------------
# Outputs: every value the commands need, then the commands themselves
# ---------------------------------------------------------------------------

output "primary_region" {
  value = var.primary_region
}

output "dr_region" {
  value = var.dr_region
}

output "resource_type" {
  value = "EC2 instance"
}

output "resource_name" {
  value = aws_instance.this.tags["Name"]
}

output "resource_arn" {
  description = "Pass this as --resource-arn"
  value       = aws_instance.this.arn
}

output "instance_id" {
  value = aws_instance.this.id
}

output "root_volume_id" {
  value = aws_instance.this.root_block_device[0].volume_id
}

output "primary_vault_name" {
  value = aws_backup_vault.primary.name
}

output "primary_vault_arn" {
  value = aws_backup_vault.primary.arn
}

output "dr_vault_name" {
  value = aws_backup_vault.dr.name
}

output "dr_vault_arn" {
  description = "Pass this as --destination-backup-vault-arn"
  value       = aws_backup_vault.dr.arn
}

output "locked_vault_name" {
  value = local.locked_vault_name
}

output "locked_vault_region" {
  value = local.locked_vault_region
}

output "lock_mode" {
  value = var.lock_mode == "compliance" ? "compliance (permanent after ${var.lock_grace_days} days)" : "governance (removable any time)"
}

output "backup_role_name" {
  value = aws_iam_role.backup.name
}

output "backup_role_arn" {
  description = "Pass this as --iam-role-arn"
  value       = aws_iam_role.backup.arn
}

output "backup_plan_name" {
  value = aws_backup_plan.this.name
}

output "backup_plan_id" {
  value = aws_backup_plan.this.id
}

output "backup_selection_id" {
  value = aws_backup_selection.this.id
}

output "retention_days" {
  value = var.retention_days
}

output "commands" {
  description = "On-demand backup job and copy job, ready to paste"
  value = join("\n", [
    "# 1. On-demand backup job:",
    "aws backup start-backup-job --backup-vault-name ${aws_backup_vault.primary.name} --resource-arn ${aws_instance.this.arn} --iam-role-arn ${aws_iam_role.backup.arn} --lifecycle DeleteAfterDays=${var.retention_days} --region ${var.primary_region}",
    "# 2. Watch the backup job (use BackupJobId from step 1):",
    "aws backup describe-backup-job --backup-job-id <BackupJobId> --region ${var.primary_region}",
    "# 3. List recovery points for this instance:",
    "aws backup list-recovery-points-by-resource --resource-arn ${aws_instance.this.arn} --region ${var.primary_region}",
    "# 4. On-demand copy job to the DR vault (use RecoveryPointArn from step 1 or 3):",
    "aws backup start-copy-job --recovery-point-arn <RecoveryPointArn> --source-backup-vault-name ${aws_backup_vault.primary.name} --destination-backup-vault-arn ${aws_backup_vault.dr.arn} --iam-role-arn ${aws_iam_role.backup.arn} --lifecycle DeleteAfterDays=${var.retention_days} --region ${var.primary_region}",
    "# 5. Watch the copy job (use CopyJobId from step 4):",
    "aws backup describe-copy-job --copy-job-id <CopyJobId> --region ${var.primary_region}",
    "# 6. Confirm the copy is in the DR vault:",
    "aws backup list-recovery-points-by-backup-vault --backup-vault-name ${aws_backup_vault.dr.name} --region ${var.dr_region}",
    "# 7. Confirm the lock:",
    "aws backup describe-backup-vault --backup-vault-name ${local.locked_vault_name} --region ${local.locked_vault_region}",
    "# 8. Remove the lock (governance: any time; compliance: grace period only):",
    "aws backup delete-backup-vault-lock-configuration --backup-vault-name ${local.locked_vault_name} --region ${local.locked_vault_region}",
  ])
}

output "instance_state" {
  description = "Instance state after apply. Every stack leaves its instance running."
  value       = aws_ec2_instance_state.this.state
}

output "cost_estimate" {
  description = "Approximate cost, us-east-1 list prices"
  value = join("\n", [
    "One-time at creation : $0.02 (first DR copy moves 1 GB cross-region)",
    "Per hour as deployed : $0.01141/hr  RUNNING: t3.micro (no public IP) + 8 GB gp3 + 1 GB recovery point in each vault",
    "Per hour if stopped  : $0.00101/hr  (no compute or public IPv4; EBS, snapshots and backups still bill)",
    "Per day / month      : ~$0.27/day | ~$8.33/month (as deployed)",
    "TOTAL per hour       : $0.01141/hr as deployed (instance left running) | $0.00101/hr if you stop it",
    "AWS Backup breakdown - backs up: instance (root vol), kept 7 day(s)",
    "  Backup job, same region (primary vault): $0.00 per job",
    "  Primary vault storage : 1 GB x $0.05/GB-mo = $0.05/month ($0.00007/hr)",
    "  Copy job to DR vault  : $0.00 per job",
    "  Copy transfer         : $0.02/GB cross-region - first copy 1 GB = $0.02, later copies changed blocks only (<$0.01)",
    "  DR vault storage      : 1 GB x $0.05/GB-mo = $0.05/month ($0.00007/hr)",
    "  Backup total          : $0.10/month storage + $0.02 first copy",
    "  Restore (EC2/EBS)     : $0.00 - you pay only for the new instance/volume",
  ])
}

output "copy_job_requirements" {
  description = "Everything an AWS Backup copy job from this folder needs."
  value = join("\n", [
    "1. Service role: ${aws_iam_role.backup.arn}",
    "   policies: ${join(", ", [aws_iam_role_policy_attachment.backup.policy_arn, aws_iam_role_policy_attachment.restore.policy_arn])}",
    "2. DR vault access policy: backup:CopyIntoBackupVault allowed on ${aws_backup_vault.dr.name} (${var.dr_region})",
    "3. Service opt-in: EC2 ON in ${var.primary_region} and ${var.dr_region}",
    "4. Run start-copy-job in ${var.primary_region} after the backup job is COMPLETED",
    "5. --lifecycle DeleteAfterDays must fit the locked vault's min/max retention",
    "6. Your CLI user: backup:StartCopyJob, backup:DescribeCopyJob, iam:PassRole on ${aws_iam_role.backup.name}",
    "7. Default KMS keys only, so no extra KMS grants needed",
  ])
}
