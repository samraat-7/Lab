# Free-tier posture fixtures

Twenty standalone Terraform stacks for exercising backup-posture scoring against
real AWS resources: ten EC2/EBS stacks and ten S3 stacks.

Each directory is a complete, independent root module with its own provider
block. There is no shared state and no root module tying them together. That is
deliberate: **you cannot run all twenty at once inside the free tier**.

| Path | Contents |
|---|---|
| `ec2/` | 10 EC2/EBS stacks (`ec2-01` … `ec2-09`, `ec2-backup-dr`) plus `up.sh` / `down.sh` |
| `s3/` | 10 S3 stacks (`s3-01` … `s3-08`, `s3-backup-dr`, `s3-replication`) plus `up.sh` / `down.sh` |
| `aws-detailed-cost-report.xlsx` | Cost of every stack in USD, per hour / day / month, with the rates used |
| `Forttic-Testcases.xlsx` | Test cases for the scanner |
| `SLA/` | Sample backup and DR SLA documents |
| `Report/` | Sample report templates |

Requirements: Terraform ≥ 1.5, AWS provider ~> 5.0, the AWS CLI, and bash (Git
Bash on Windows) for `up.sh` / `down.sh` and for the stacks that run backup
jobs at apply.

---

## 1. Cost and the free tier

Prices are us-east-1 on-demand list prices. Every `main.tf` starts with a `COST`
comment and prints the same figures with `terraform output cost_estimate`.
`aws-detailed-cost-report.xlsx` has the full breakdown.

**Every EC2 stack with an instance leaves it running** (all except `ec2-06`,
which is a standalone EBS volume). A t3.micro (Amazon Linux) is $0.0104/hr and
the auto-assigned public IPv4 on `ec2-01` … `ec2-05` and `ec2-07` is $0.005/hr.

| | Per hour | Per month |
|---|---|---|
| One EC2 stack with an instance | $0.011 – $0.016 | $8.31 – $12.01 |
| `ec2-06` (1 GB volume, no instance) | $0.00011 | $0.08 |
| All 10 EC2 stacks | $0.133 | $96.95 |
| One S3 stack, empty bucket | $0 | $0 |
| One S3 stack, per 1 GB stored | $0.00003 – $0.00017 | $0.023 – $0.123 |

These numbers assume a **legacy account created before 15 July 2025**. Accounts
created on or after that date are on the credit-based Free Plan and have no
per-service allowances; everything draws from the credit pool instead. Check
which one you have in Billing → Free Tier.

| Allowance | Limit | What the fixtures consume |
|---|---|---|
| EC2 hours | 750 hrs/month, **per account** | 1 running instance = 730 hrs/month. Two exhaust it in ~15 days. |
| EBS storage | 30 GB | 8 GB root per instance (AL2023 minimum) + 1 GB data volume where present; `ec2-06` is a lone 1 GB volume. |
| EBS snapshots / AWS Backup | billed per GB-month | Root ~1 GB, empty data volumes ~0 GB. |
| Public IPv4 | 750 hrs/month for 12 months | One per running instance in `ec2-01` … `ec2-05` and `ec2-07`. |
| S3 storage | 5 GB | Empty buckets cost nothing. All ten can run together. |

### What fits at the same time

| Group | Safe concurrency | Why |
|---|---|---|
| S3 | all 10 | Empty buckets consume no storage |
| EC2 | **2** | 750 instance-hours and 30 GB EBS per account |

Nothing here creates a NAT gateway, Elastic IP, customer-managed KMS key,
Route 53 zone or load balancer. The default VPC is used throughout. SSE-S3
(`AES256`) is used instead of SSE-KMS because a customer-managed key costs
$1/month. Cross-region stacks copy to **us-west-2** and pay $0.02/GB for each
first copy.

---

## 2. The stacks

Adjacent stacks differ by one protection mechanism, so any difference in posture
score between them is attributable to that one change.

### EC2 / EBS (`ec2/`)

| Stack | What it creates | What it tests |
|---|---|---|
| ec2-01 | Instance + 8 GB root. No protection | Unprotected baseline |
| ec2-02 | + encrypted 1 GB data volume | Two volumes on one instance (per-volume scoring) |
| ec2-03 | + data volume + one manual EBS snapshot | Snapshot is an artifact; gives the volume copy_count 1 |
| ec2-04 | + data volume + snapshot + AMI | AMI must not be counted as an unprotected resource |
| ec2-05 | + data volume + DLM policy (every 24 h, keep 1) | Native snapshots without AWS Backup |
| ec2-06 | **Standalone** encrypted 1 GB gp3 volume, no instance, no protection | Unattached volume found and scored on its own |
| ec2-07 | Instance, AWS Backup (tag selection) + copy to DR vault, **DR vault locked (compliance, 3 days)** | Immutable copy in another region |
| ec2-08 | AWS Backup of the instance + copy to DR vault, DR locked (governance) | Instance ARN selection; recovery point is an AMI |
| ec2-09 | AWS Backup of the **data volume only** + copy to DR, DR locked (governance) | Volume ARN selection; recovery point is an EBS snapshot |
| ec2-backup-dr | Instance + data volume backup + copy to DR, **DR locked (compliance, 5 days)** | One recovery point covering every attached volume |

In every backup stack only the **DR vault** is locked; the primary vault is not.

**On-demand backup and copy jobs:**

- **ec2-07 and ec2-09** run one backup job and one copy job at the end of
  `terraform apply` and wait for both (15–40 minutes). Skip them with
  `-var="run_backup_now=false"`; run them again with
  `terraform apply -replace='terraform_data.backup_now[0]'`.
- **ec2-08 and ec2-backup-dr** print the commands to run by hand:
  `terraform output -raw commands` (ec2-08), `-raw next_steps` (ec2-backup-dr).

### S3 (`s3/`)

| Stack | What it creates | What it tests |
|---|---|---|
| s3-01 | Bare bucket, public access blocked | Unprotected baseline |
| s3-02 | + versioning | Versioning without a separate copy |
| s3-03 | + lifecycle rule + SSE-S3 encryption | Readable retention_days; encryption is not a copy |
| s3-04 | Cross-region replication (CRR) to us-west-2 | Copy in another region |
| s3-05 | AWS Backup, 1 vault, no lock (daily) | Backup copy in the same region |
| s3-06 | AWS Backup + copy to DR vault, no lock (weekly) | Two copies, not immutable |
| s3-07 | S3 Object Lock, GOVERNANCE, 1 day | Immutable without a copy |
| s3-08 | CRR + SRR + Object Lock on all three buckets | Two copies, immutable |
| s3-backup-dr | AWS Backup + copy to DR vault, **DR locked (compliance, 3 days)** | Immutable backup in another region |
| s3-replication | CRR + SRR + Object Lock (3 days) + SSE-S3 | Replication demo with three buckets |

The S3 backup stacks print their backup and copy commands
(`terraform output`); nothing runs at apply. Replication copies only objects
written after apply.

---

## 3. Before the first backup

**AWS Backup → Settings → Service opt-in** must have EC2, EBS and S3 turned on,
in us-east-1 **and** us-west-2 for the copy stacks. If it is off, the plan is
created but nothing is backed up, and nothing reports an error.

---

## 4. Running them

Deploy one stack:

```bash
cd ec2/ec2-01
terraform init
terraform apply
terraform output cost_estimate
```

Tear it down:

```bash
terraform destroy
```

Or a whole group from its folder (`ec2/` or `s3/`):

```bash
./up.sh                    # apply every stack in the folder
./up.sh ec2-01 ec2-05      # only the named stacks
./down.sh                  # destroy every stack (asks first; -y skips the prompt)
```

Confirm nothing is still running:

```bash
aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" --query "Reservations[].Instances[].[InstanceId,Tags[?Key=='Name']|[0].Value]" --output table
```

Check spend so far this month:

```bash
aws ce get-cost-and-usage --time-period Start=2026-10-01,End=2026-11-01 --granularity MONTHLY --metrics "UnblendedCost" --group-by Type=DIMENSION,Key=SERVICE
```

---

## 5. Teardown traps

| Stack | Problem | Fix |
|---|---|---|
| ec2-07, ec2-backup-dr, s3-backup-dr | The DR vault lock is **COMPLIANCE**: after the grace period (3 or 5 days) nobody, including root, can remove it, and the vault cannot be deleted while it holds recovery points | Destroy inside the grace period, or wait for the recovery points to expire (retention 1–7 days) |
| ec2-08, ec2-09 | DR vault lock is GOVERNANCE | Terraform removes it; destroy works any time |
| s3-07, s3-08, s3-replication | Object Lock blocks deleting objects until retention ends | Keep buckets empty, or wait out the 1–3 day retention |
| ec2-05 | Snapshots that DLM created are not managed by Terraform and stay after destroy | Delete them in EC2 → Snapshots |
| ec2-04 | AMI and its backing snapshots | Check EC2 → AMIs and Snapshots after destroy |

A good habit: apply a stack, let the scanner collect, destroy it the same day.

---

## 6. Set a budget before you start

Two budgets are free per account:

```bash
aws budgets create-budget --account-id "$(aws sts get-caller-identity --query Account --output text)" --budget '{"BudgetName":"posture-fixtures","BudgetLimit":{"Amount":"5","Unit":"USD"},"TimeUnit":"MONTHLY","BudgetType":"COST"}'
```

Most resources carry the tag `Fixture = posture-test`. ec2-08, ec2-09,
ec2-backup-dr, s3-backup-dr and s3-replication name their resources with a
prefix instead (`ec2-08`, `ec2-09`, `ft-ec2bkp`, `ft-s3bkp`, `ft-repl`). Find
strays with:

```bash
aws resourcegroupstaggingapi get-resources --tag-filters "Key=Fixture,Values=posture-test" --query "ResourceTagMappingList[].ResourceARN" --output table
```

---

## 7. What never goes in this repo

`.gitignore` keeps out `terraform.tfstate*` (state can contain your account ID
and resource ARNs), `.terraform/` provider caches, `.terraform.lock.hcl` and
`*.tfvars`. `terraform init` creates the lock file again on each machine, using
the newest provider that matches `~> 5.0`.
