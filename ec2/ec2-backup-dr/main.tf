# EC2 instance + attached volume + AWS Backup + cross-region copy to a DR vault
# + Vault Lock. The EC2 twin of the S3 backup stack.
#
#   instance (root + data volume)  --daily backup-->  primary vault (us-east-1)
#                                                            |
#                                                            +--copy--> DR vault (us-west-2)
#
# Backing up an EC2 instance backs up the instance configuration AND every EBS
# volume attached to it, as one recovery point. The data volume needs no
# separate selection.
#
# Only the DR vault gets a Vault Lock (COMPLIANCE mode, 5-day grace period).
# The primary vault is not locked.
#
# READ THIS BEFORE APPLYING
#   For the first 5 days (the grace period) the lock can still be removed.
#   After that it is permanent: nobody, including the root user and AWS, can
#   remove it or shorten retention. A locked vault cannot be deleted while it
#   holds recovery points, so `terraform destroy` fails until they expire.
#   Retention here is 7 days, so cleanup takes at most 7 days after the last
#   backup. Set enable_vault_lock = false to skip the lock entirely.
#
# ON-DEMAND BACKUP + COPY (manual - terraform apply does NOT run them)
#   The plan backs up and copies daily on its own. To do it now, run the
#   commands printed by: terraform output -raw next_steps
#
# COST (us-east-1 on-demand list prices, before any free tier or credits)
#   Rates used: t3.micro $0.0104/hr | public IPv4 $0.005/hr | gp3 $0.08/GB-mo
#   ($0.00011/GB-hr) | snapshot / AWS Backup $0.05/GB-mo ($0.000068/GB-hr) |
#   cross-region copy transfer $0.02/GB. Vaults, plans, DLM, IAM, locks: free.
#   EC2 and EBS bill per second (60 s minimum); there is no creation fee.
#   One-time at creation : $0.02 (first DR copy moves 1 GB cross-region: 1 GB root + ~0 GB empty data volume)
#   Per hour as deployed : $0.01152/hr  RUNNING: t3.micro (no public IP) + 9 GB gp3 + 1 GB recovery point in each vault
#   Per hour if stopped  : $0.00112/hr  (no compute or public IPv4; EBS, snapshots and backups still bill)
#   Per day / month      : ~$0.28/day | ~$8.41/month (as deployed)
#   TOTAL per hour       : $0.01152/hr as deployed (instance left running) | $0.00112/hr if you stop it
#   Stop the instance in the console to drop to ~$0.00112/hr.
#   AWS Backup breakdown - backs up: instance (root + data vol), kept 7 day(s)
#     Backup job, same region (primary vault): $0.00 per job
#     Primary vault storage : 1 GB x $0.05/GB-mo = $0.05/month ($0.00007/hr)
#     Copy job to DR vault  : $0.00 per job
#     Copy transfer         : $0.02/GB cross-region - first copy 1 GB = $0.02, later copies changed blocks only (<$0.01)
#     DR vault storage      : 1 GB x $0.05/GB-mo = $0.05/month ($0.00007/hr)
#     Backup total          : $0.10/month storage + $0.02 first copy
#     Restore (EC2/EBS)     : $0.00 - you pay only for the new instance/volume
#   Later daily copies are incremental: well under $0.01 each.

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
  default = "ft-ec2bkp"
}

variable "instance_type" {
  description = "t3.micro and t2.micro are the cheapest widely available."
  type        = string
  default     = "t3.micro"
}

variable "root_volume_size" {
  description = "GiB. 8 is the Amazon Linux 2023 AMI minimum."
  type        = number
  default     = 8

  validation {
    condition     = var.root_volume_size >= 8
    error_message = "The Amazon Linux 2023 AMI is 8 GiB, so the root volume cannot be smaller than 8."
  }
}

variable "data_volume_size" {
  description = "GiB of the extra attached volume. 1 is the minimum for gp3."
  type        = number
  default     = 1
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

variable "enable_vault_lock" {
  description = "Apply Vault Lock (compliance mode) to the DR vault"
  type        = bool
  default     = true
}

variable "lock_grace_days" {
  description = "Grace period before the lock becomes permanent. AWS minimum is 3."
  type        = number
  default     = 5

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
  default     = 365
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

  # The lock rejects any backup whose retention is outside this range, so fail
  # at plan time instead of at the first backup.
  retention_ok = (
    var.retention_days >= var.lock_min_retention_days &&
    var.retention_days <= var.lock_max_retention_days
  )
}

# ---------------------------------------------------------------------------
# Network: default VPC, in an AZ that actually offers the instance type
# (us-east-1e does not offer t3.micro, and subnet order is not guaranteed).
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

# Amazon Linux 2023 from the public SSM parameter, so the AMI id never goes stale.
# nonsensitive(): it is a public AMI id, and hiding it makes plans unreadable.
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
# The instance and its volumes
# ---------------------------------------------------------------------------

resource "aws_instance" "this" {
  ami                    = nonsensitive(data.aws_ssm_parameter.al2023.value)
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.usable.ids[0]
  vpc_security_group_ids = [aws_security_group.this.id]

  # Default-VPC subnets hand out a public IPv4 address by default, which
  # costs about $3.65/month. Nothing here needs one.
  associate_public_ip_address = false

  metadata_options {
    http_tokens   = "required" # IMDSv2 only
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
      error_message = "No default-VPC subnet in ${var.primary_region} sits in an AZ that offers ${var.instance_type}. Try t2.micro or another region."
    }

    precondition {
      condition     = local.retention_ok
      error_message = "retention_days must sit between lock_min_retention_days and lock_max_retention_days, or the vault lock will reject every backup."
    }
  }
}

# The data volume must live in the same AZ as the instance.
resource "aws_ebs_volume" "data" {
  availability_zone = aws_instance.this.availability_zone
  type              = "gp3"
  size              = var.data_volume_size
  encrypted         = true

  tags = {
    Name = "${var.name_prefix}-data"
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.this.id

  # Lets terraform destroy detach cleanly instead of hanging.
  stop_instance_before_detaching = true
}

# Instance state, set last, after the data volume is attached. Running by
# default; set stop_instance = true to stop it.
resource "aws_ec2_instance_state" "this" {
  instance_id = aws_instance.this.id
  state       = var.stop_instance ? "stopped" : "running"

  depends_on = [aws_volume_attachment.data]
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
# IAM role AWS Backup uses. EC2/EBS use the generic service-role policies; S3
# has its own separate ones, so this role would not work for a bucket.
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
# Backup plan: daily at 05:00 UTC, kept 7 days, copied to the DR vault
# ---------------------------------------------------------------------------

resource "aws_backup_plan" "ec2" {
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

resource "aws_backup_selection" "ec2" {
  name         = "${var.name_prefix}-selection"
  plan_id      = aws_backup_plan.ec2.id
  iam_role_arn = aws_iam_role.backup.arn

  # The instance ARN is enough: its attached volumes come with it.
  resources = [aws_instance.this.arn]

  depends_on = [
    aws_volume_attachment.data,
    aws_iam_role_policy_attachment.backup,
    aws_iam_role_policy_attachment.restore,
  ]
}

# ---------------------------------------------------------------------------
# Vault Lock, compliance mode. changeable_for_days is what makes it compliance
# mode: leave it out and the lock is governance mode, which can always be
# removed. The 5 days start the moment the lock is created.
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

  depends_on = [aws_backup_plan.ec2]
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "instance_id" {
  value = aws_instance.this.id
}

output "instance_arn" {
  value = aws_instance.this.arn
}

output "root_volume_id" {
  value = aws_instance.this.root_block_device[0].volume_id
}

output "data_volume_id" {
  value = aws_ebs_volume.data.id
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
  description = "On-demand backup + copy commands, run by hand (apply does not run them)."
  value = join("\n", [
    "# 0. Check AWS Backup > Settings > Service opt-in: EC2 and EBS must be ON, in ${var.primary_region} (and ${var.dr_region} for the copy). If off, nothing backs up and nothing errors.",
    "# 1. Back up now (instance + both volumes):",
    "aws backup start-backup-job --backup-vault-name ${aws_backup_vault.primary.name} --resource-arn ${aws_instance.this.arn} --iam-role-arn ${aws_iam_role.backup.arn} --lifecycle DeleteAfterDays=${var.retention_days} --region ${var.primary_region}",
    "# 2. Watch the backup job until State = COMPLETED (BackupJobId comes from step 1):",
    "aws backup describe-backup-job --backup-job-id <backup-job-id> --query '[State,RecoveryPointArn,StatusMessage]' --region ${var.primary_region}",
    "#    then find the recovery point:",
    "aws backup list-recovery-points-by-backup-vault --backup-vault-name ${aws_backup_vault.primary.name} --query 'RecoveryPoints[].RecoveryPointArn' --region ${var.primary_region}",
    "# 3. Copy it to the DR vault now (run in the SOURCE region):",
    "aws backup start-copy-job --recovery-point-arn <arn-from-step-2> --source-backup-vault-name ${aws_backup_vault.primary.name} --destination-backup-vault-arn ${aws_backup_vault.dr.arn} --iam-role-arn ${aws_iam_role.backup.arn} --lifecycle DeleteAfterDays=${var.retention_days} --region ${var.primary_region}",
    "# 4. Watch the copy job until State = COMPLETED (CopyJobId comes from step 3):",
    "aws backup describe-copy-job --copy-job-id <copy-job-id> --query 'CopyJob.[State,StatusMessage]' --region ${var.primary_region}",
    "# 5. Check the copy landed:",
    "aws backup list-recovery-points-by-backup-vault --backup-vault-name ${aws_backup_vault.dr.name} --region ${var.dr_region}",
  ])
}

output "instance_state" {
  description = "Instance state after apply. Every stack leaves its instance running."
  value       = aws_ec2_instance_state.this.state
}

output "cost_estimate" {
  description = "Approximate cost, us-east-1 list prices"
  value = join("\n", [
    "One-time at creation : $0.02 (first DR copy moves 1 GB cross-region: 1 GB root + ~0 GB empty data volume)",
    "Per hour as deployed : $0.01152/hr  RUNNING: t3.micro (no public IP) + 9 GB gp3 + 1 GB recovery point in each vault",
    "Per hour if stopped  : $0.00112/hr  (no compute or public IPv4; EBS, snapshots and backups still bill)",
    "Per day / month      : ~$0.28/day | ~$8.41/month (as deployed)",
    "TOTAL per hour       : $0.01152/hr as deployed (instance left running) | $0.00112/hr if you stop it",
    "AWS Backup breakdown - backs up: instance (root + data vol), kept 7 day(s)",
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
