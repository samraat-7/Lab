# ec2-07 — instance + AWS Backup plan + copy to a DR vault, DR vault LOCKED
#
#   instance --daily backup--> ft-posture-vault-07    (us-east-1)  not locked
#                                   |
#                                   +--copy--> ft-posture-dr-vault-07 (us-west-2)  LOCKED
#
# Standard AWS Backup path (tag selection) plus a DR vault, a copy_action and a
# lock on the DR vault. Only the DR vault is locked; the primary vault is not.
# Posture expectation: this is the EC2 fixture that should move
# immutable_status above 0, through the locked DR copy.
#
# VAULT LOCK WARNING
#   changeable_for_days = 3 puts the lock in COMPLIANCE mode: it can be removed
#   only during that 3-day grace period, then it is permanent for everyone,
#   root included, and the DR vault cannot be deleted until every recovery
#   point in it expires. (Leaving changeable_for_days out would make it a
#   governance lock instead.) Destroy this stack inside the 3-day window.
#
# ON-DEMAND BACKUP + COPY AT APPLY
#   terraform apply ends by running ONE on-demand backup job of the instance
#   into the primary vault and ONE copy job of that recovery point to the DR vault, and waits
#   for both to finish (roughly 15-40 minutes). Needs the AWS CLI and bash on
#   this machine (Git Bash on Windows). Skip it with -var="run_backup_now=false".
#   Run it again later with: terraform apply -replace='terraform_data.backup_now[0]'
#
# COST (us-east-1 on-demand list prices, before any free tier or credits)
#   Rates used: t3.micro $0.0104/hr | public IPv4 $0.005/hr | gp3 $0.08/GB-mo
#   ($0.00011/GB-hr) | snapshot / AWS Backup $0.05/GB-mo ($0.000068/GB-hr) |
#   cross-region copy transfer $0.02/GB. Vaults, plans, DLM, IAM, locks: free.
#   EC2 and EBS bill per second (60 s minimum); there is no creation fee.
#   One-time at creation : $0.02 (first DR copy moves 1 GB cross-region)
#   Per hour as deployed : $0.01641/hr  RUNNING: t3.micro + public IPv4 + 8 GB gp3 + 1 GB recovery point in each vault
#   Per hour if stopped  : $0.00101/hr  (no compute or public IPv4; EBS, snapshots and backups still bill)
#   Per day / month      : ~$0.39/day | ~$11.98/month (as deployed)
#   TOTAL per hour       : $0.01641/hr as deployed (instance left running, incl. 1 on-demand backup + 1 copy) | $0.00101/hr if you stop it
#   AWS Backup breakdown - backs up: instance (root vol), kept 1 day(s)
#     Backup job, same region (primary vault): $0.00 per job
#     Primary vault storage : 1 GB x $0.05/GB-mo = $0.05/month ($0.00007/hr)
#     Copy job to DR vault  : $0.00 per job
#     Copy transfer         : $0.02/GB cross-region - first copy 1 GB = $0.02, later copies changed blocks only (<$0.01)
#     DR vault storage      : 1 GB x $0.05/GB-mo = $0.05/month ($0.00007/hr)
#     Backup total          : $0.10/month storage + $0.02 first copy
#     Restore (EC2/EBS)     : $0.00 - you pay only for the new instance/volume
#   Stop the instance in the console to drop to ~$0.00101/hr.

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
  description = "Region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "dr_region" {
  description = "Region of the DR vault. Must differ from region."
  type        = string
  default     = "us-west-2"

  validation {
    condition     = var.dr_region != var.region
    error_message = "dr_region must be a different region from region."
  }
}

variable "instance_type" {
  description = "Free-tier eligible instance type"
  type        = string
  default     = "t3.micro"
}

variable "retention_days" {
  description = "Recovery point retention - keep at 1 for fixtures"
  type        = number
  default     = 1
}

variable "lock_changeable_for_days" {
  description = "Compliance-mode grace period for the DR vault lock. AWS minimum is 3."
  type        = number
  default     = 3

  validation {
    condition     = var.lock_changeable_for_days >= 3
    error_message = "Must be at least 3 days (AWS minimum)."
  }
}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_vpc" "default" {
  default = true
}

# Only subnets in AZs that offer the instance type. Subnet order is not
# guaranteed, and us-east-1e does not offer t3.micro.
data "aws_ec2_instance_type_offerings" "supported" {
  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }

  location_type = "availability-zone"
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "availability-zone"
    values = data.aws_ec2_instance_type_offerings.supported.locations
  }
}

resource "aws_security_group" "this" {
  name        = "ft-posture-ec2-07"
  description = "Egress only"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "ft-posture-ec2-07"
    Fixture = "posture-test"
  }
}

resource "aws_instance" "this" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.this.id]

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    delete_on_termination = true
    encrypted             = true

    tags = {
      Name    = "ec2-07-root"
      Fixture = "posture-test"
    }
  }

  tags = {
    Name       = "ec2-07"
    Fixture    = "posture-test"
    Protection = "aws-backup-locked"
    BackupSet  = "ft-posture-07"
    FreeTier   = "true"
  }
}

data "aws_caller_identity" "current" {}

resource "aws_backup_vault" "this" {
  name          = "ft-posture-vault-07"
  force_destroy = true

  tags = {
    Fixture = "posture-test"
    Locked  = "false"
  }
}

resource "aws_backup_vault" "dr" {
  provider      = aws.dr
  name          = "ft-posture-dr-vault-07"
  force_destroy = true

  tags = {
    Fixture = "posture-test"
    Locked  = "true"
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
#   5. --lifecycle DeleteAfterDays sits inside the DR vault lock's 1-7 day
#      retention range, otherwise the copy is rejected.
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

# Only the DR vault is locked.
resource "aws_backup_vault_lock_configuration" "dr" {
  provider = aws.dr

  backup_vault_name   = aws_backup_vault.dr.name
  changeable_for_days = var.lock_changeable_for_days
  min_retention_days  = 1
  max_retention_days  = 7
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
  name               = "ft-posture-backup-ec2-07"
  assume_role_policy = data.aws_iam_policy_document.backup_assume.json

  tags = {
    Fixture = "posture-test"
  }
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "restore" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

resource "aws_backup_plan" "this" {
  name = "ft-posture-plan-07"

  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.this.name
    schedule          = "cron(0 3 * * ? *)"
    start_window      = 60
    completion_window = 180

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

  tags = {
    Fixture = "posture-test"
  }
}

resource "aws_backup_selection" "this" {
  name         = "ft-posture-selection-07"
  iam_role_arn = aws_iam_role.backup.arn
  plan_id      = aws_backup_plan.this.id

  selection_tag {
    type  = "STRINGEQUALS"
    key   = "BackupSet"
    value = "ft-posture-07"
  }
}

# ---------------------------------------------------------------------------
# One on-demand backup job + one copy job to the DR vault, run once at the
# end of apply on this machine with the AWS CLI. Apply fails if a job fails.
# ---------------------------------------------------------------------------

variable "run_backup_now" {
  description = "Run one on-demand backup job and one copy job at the end of apply"
  type        = bool
  default     = true
}

resource "terraform_data" "backup_now" {
  count = var.run_backup_now ? 1 : 0

  # Runs again only if the backed-up resource is replaced.
  triggers_replace = [aws_instance.this.arn]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]

    environment = {
      REGION       = var.region
      VAULT        = aws_backup_vault.this.name
      RESOURCE_ARN = aws_instance.this.arn
      ROLE_ARN     = aws_iam_role.backup.arn
      DR_VAULT_ARN = aws_backup_vault.dr.arn
      DAYS         = var.retention_days
    }

    command = <<-EOT
      set -euo pipefail

      aws_() { aws "$@" --region "$REGION" --output text | tr -d '\r'; }

      # $1 describe command, $2 id flag, $3 id, $4 query prefix ("" or "CopyJob.")
      wait_job() {
        for _ in $(seq 1 180); do
          state=$(aws_ backup "$1" "$2" "$3" --query "$4State")
          echo "$1 $3: $state"
          case "$state" in
            COMPLETED) return 0 ;;
            FAILED | ABORTED | EXPIRED | PARTIAL)
              aws_ backup "$1" "$2" "$3" --query "$4StatusMessage"
              return 1 ;;
          esac
          sleep 30
        done
        echo "timed out after 90 minutes"
        return 1
      }

      # A brand-new IAM role can take a few seconds before AWS Backup can use it.
      job=""
      for _ in 1 2 3 4 5 6; do
        job=$(aws_ backup start-backup-job \
          --backup-vault-name "$VAULT" \
          --resource-arn "$RESOURCE_ARN" \
          --iam-role-arn "$ROLE_ARN" \
          --lifecycle "DeleteAfterDays=$DAYS" \
          --query BackupJobId) && break
        echo "start-backup-job failed, retrying in 20 s"
        sleep 20
      done
      [ -n "$job" ] || { echo "could not start the backup job"; exit 1; }
      echo "backup job: $job"
      wait_job describe-backup-job --backup-job-id "$job" ""

      rp=$(aws_ backup describe-backup-job --backup-job-id "$job" --query RecoveryPointArn)
      echo "recovery point: $rp"

      if [ -n "$${DR_VAULT_ARN:-}" ]; then
        copy=$(aws_ backup start-copy-job \
          --recovery-point-arn "$rp" \
          --source-backup-vault-name "$VAULT" \
          --destination-backup-vault-arn "$DR_VAULT_ARN" \
          --iam-role-arn "$ROLE_ARN" \
          --lifecycle "DeleteAfterDays=$DAYS" \
          --query CopyJobId)
        echo "copy job: $copy"
        wait_job describe-copy-job --copy-job-id "$copy" "CopyJob."
      fi
    EOT
  }

  depends_on = [
    aws_backup_selection.this,
    aws_iam_role_policy_attachment.backup,
    aws_iam_role_policy_attachment.restore,
    aws_backup_vault_policy.dr,
    aws_backup_vault_lock_configuration.dr,
  ]
}

output "instance_id" {
  value = aws_instance.this.id
}

output "vault_name" {
  value = aws_backup_vault.this.name
}

output "dr_vault_name" {
  value = aws_backup_vault.dr.name
}

output "dr_vault_arn" {
  value = aws_backup_vault.dr.arn
}

output "locked_vault" {
  value = "${aws_backup_vault.dr.name} (${var.dr_region}) - primary vault is not locked"
}

output "instance_state" {
  description = "Instance state after apply. Every stack leaves its instance running."
  value       = aws_instance.this.instance_state
}

output "cost_estimate" {
  description = "Approximate cost, us-east-1 list prices"
  value = join("\n", [
    "One-time at creation : $0.02 (first DR copy moves 1 GB cross-region)",
    "Per hour as deployed : $0.01641/hr  RUNNING: t3.micro + public IPv4 + 8 GB gp3 + 1 GB recovery point in each vault",
    "Per hour if stopped  : $0.00101/hr  (no compute or public IPv4; EBS, snapshots and backups still bill)",
    "Per day / month      : ~$0.39/day | ~$11.98/month (as deployed)",
    "TOTAL per hour       : $0.01641/hr as deployed (instance left running, incl. 1 on-demand backup + 1 copy) | $0.00101/hr if you stop it",
    "AWS Backup breakdown - backs up: instance (root vol), kept 1 day(s)",
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
    "3. Service opt-in: EC2 ON in ${var.region} and ${var.dr_region}",
    "4. Run start-copy-job in ${var.region} after the backup job is COMPLETED",
    "5. --lifecycle DeleteAfterDays must be 1-7 (the DR vault lock's range)",
    "6. Your CLI user: backup:StartCopyJob, backup:DescribeCopyJob, iam:PassRole on ${aws_iam_role.backup.name}",
    "7. Default KMS keys only, so no extra KMS grants needed",
  ])
}
