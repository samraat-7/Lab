# ec2-06 — instance + AWS Backup plan, vault NOT locked
# This is the fixture for the standard AWS Backup path: a vault, a plan, a
# tag-based selection, and the IAM service role.
# Posture expectation: recovery points appear in the vault and credit the
# volume's copy_count, but immutable_status stays 0 because the vault is
# not locked. Pairs with ec2-07, which adds a DR copy and locks the DR vault.
#
# ON-DEMAND BACKUP (manual - terraform apply does NOT run it)
#   The plan backs up daily on its own. To back up now, run the commands
#   printed by: terraform output -raw backup_now
#   (start-backup-job, then describe-backup-job until State = COMPLETED).
#
# COST (us-east-1 on-demand list prices, before any free tier or credits)
#   Rates used: t3.micro $0.0104/hr | public IPv4 $0.005/hr | gp3 $0.08/GB-mo
#   ($0.00011/GB-hr) | snapshot / AWS Backup $0.05/GB-mo ($0.000068/GB-hr) |
#   cross-region copy transfer $0.02/GB. Vaults, plans, DLM, IAM, locks: free.
#   EC2 and EBS bill per second (60 s minimum); there is no creation fee.
#   One-time at creation : $0.00
#   Per hour as deployed : $0.01635/hr  RUNNING: t3.micro + public IPv4 + 8 GB gp3 + 1 GB recovery point
#   Per hour if stopped  : $0.00095/hr  (no compute or public IPv4; EBS, snapshots and backups still bill)
#   Per day / month      : ~$0.39/day | ~$11.93/month (as deployed)
#   TOTAL per hour       : $0.01635/hr as deployed (instance left running) | $0.00095/hr if you stop it
#   AWS Backup breakdown - backs up: instance (root vol), kept 1 day(s)
#     Backup job, same region (primary vault): $0.00 per job
#     Primary vault storage : 1 GB x $0.05/GB-mo = $0.05/month ($0.00007/hr)
#     Copy job              : none in this stack
#     Backup total          : $0.05/month storage
#     Restore (EC2/EBS)     : $0.00 - you pay only for the new instance/volume
#   Stop the instance in the console to drop to ~$0.00095/hr.

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
  name        = "ft-posture-ec2-06"
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
    Name    = "ft-posture-ec2-06"
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
      Name    = "ec2-06-root"
      Fixture = "posture-test"
    }
  }

  tags = {
    Name       = "ec2-06"
    Fixture    = "posture-test"
    Protection = "aws-backup-unlocked"
    BackupSet  = "ft-posture-06"
    FreeTier   = "true"
  }
}

resource "aws_backup_vault" "this" {
  name          = "ft-posture-vault-06"
  force_destroy = true

  tags = {
    Fixture = "posture-test"
    Locked  = "false"
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
  name               = "ft-posture-backup-ec2-06"
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
  name = "ft-posture-plan-06"

  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.this.name
    schedule          = "cron(0 3 * * ? *)"
    start_window      = 60
    completion_window = 180

    lifecycle {
      delete_after = var.retention_days
    }
  }

  tags = {
    Fixture = "posture-test"
  }
}

resource "aws_backup_selection" "this" {
  name         = "ft-posture-selection-06"
  iam_role_arn = aws_iam_role.backup.arn
  plan_id      = aws_backup_plan.this.id

  selection_tag {
    type  = "STRINGEQUALS"
    key   = "BackupSet"
    value = "ft-posture-06"
  }
}

output "instance_id" {
  value = aws_instance.this.id
}

output "vault_name" {
  value = aws_backup_vault.this.name
}

output "plan_id" {
  value = aws_backup_plan.this.id
}

output "backup_now" {
  description = "On-demand backup job commands, run by hand (apply does not run them)."
  value = join("\n", [
    "# 0. Check AWS Backup > Settings > Service opt-in: EC2 must be ON in ${var.region}. If off, nothing backs up and nothing errors.",
    "# 1. Start an on-demand backup job of the instance (returns BackupJobId):",
    "aws backup start-backup-job --backup-vault-name ${aws_backup_vault.this.name} --resource-arn ${aws_instance.this.arn} --iam-role-arn ${aws_iam_role.backup.arn} --lifecycle DeleteAfterDays=${var.retention_days} --region ${var.region} --query BackupJobId --output text",
    "# 2. Watch it until State = COMPLETED:",
    "aws backup describe-backup-job --backup-job-id <backup-job-id> --query '[State,RecoveryPointArn,StatusMessage]' --region ${var.region}",
    "# 3. List the recovery points in the vault:",
    "aws backup list-recovery-points-by-backup-vault --backup-vault-name ${aws_backup_vault.this.name} --region ${var.region}",
    "# No copy job: this stack has no DR vault (see ec2-07/ec2-08 for that).",
  ])
}

output "instance_state" {
  description = "Instance state after apply. Every stack leaves its instance running."
  value       = aws_instance.this.instance_state
}

output "cost_estimate" {
  description = "Approximate cost, us-east-1 list prices"
  value = join("\n", [
    "One-time at creation : $0.00",
    "Per hour as deployed : $0.01635/hr  RUNNING: t3.micro + public IPv4 + 8 GB gp3 + 1 GB recovery point",
    "Per hour if stopped  : $0.00095/hr  (no compute or public IPv4; EBS, snapshots and backups still bill)",
    "Per day / month      : ~$0.39/day | ~$11.93/month (as deployed)",
    "TOTAL per hour       : $0.01635/hr as deployed (instance left running) | $0.00095/hr if you stop it",
    "AWS Backup breakdown - backs up: instance (root vol), kept 1 day(s)",
    "  Backup job, same region (primary vault): $0.00 per job",
    "  Primary vault storage : 1 GB x $0.05/GB-mo = $0.05/month ($0.00007/hr)",
    "  Copy job              : none in this stack",
    "  Backup total          : $0.05/month storage",
    "  Restore (EC2/EBS)     : $0.00 - you pay only for the new instance/volume",
  ])
}
