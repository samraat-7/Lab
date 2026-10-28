# EC2 instance + AWS Backup + DR vault + Vault Lock

One t3.micro instance (8 GiB root + 1 GiB attached data volume) backed up daily
to a primary vault, with every backup copied to a DR vault in a second region.
Only the DR vault gets a Vault Lock, with a 5-day grace period. The primary
vault is not locked.

| Piece | Where |
|---|---|
| EC2 instance + data volume | us-east-1 |
| Primary vault | us-east-1 |
| DR vault | us-west-2 |
| Backup plan | daily 05:00 UTC, 7-day retention, copy to DR |
| Vault Lock | DR vault only: compliance mode, 5-day grace, min 1 / max 365 days |

Backing up the instance covers its attached volumes. Root and data volume land
in one recovery point, so there is no separate volume selection.

## Run it

```powershell
aws sts get-caller-identity
terraform init
terraform plan -out tfplan
terraform apply tfplan
terraform output next_steps
```

Needs a default VPC in the region (every new account has one unless it was deleted).

**Check one setting first:** AWS Backup > Settings > Service opt-in. **EC2** and
**EBS** must be on, in both regions. If one is off, the plan is created but backs
up nothing, with no error.

`terraform output next_steps` prints ready-made commands for an on-demand backup
job and copy job, so you do not have to wait for 05:00 UTC.

## Read this about the lock

- Days 0 to 5 (grace period): the lock can still be removed with
  `aws backup delete-backup-vault-lock-configuration --backup-vault-name <vault>`
  (run it against the DR vault, in the DR region).
- After day 5 it is permanent. Nobody can remove it, including the root user and AWS.
- A locked vault cannot be deleted while it holds recovery points. They expire
  after 7 days on their own, so `terraform destroy` works about 7 days after the
  last backup. Until then it fails partway.
- Just testing? `terraform apply -var="enable_vault_lock=false"` skips the lock.
- Every backup must have retention between 1 and 365 days or the vault rejects
  it. The plan checks this for you.

## Options

| Variable | Default | Meaning |
|---|---|---|
| `stop_instance` | `true` | Stop the instance after creating it. A stopped instance is still backed up. |
| `retention_days` | `7` | Days recovery points are kept, in both vaults |
| `enable_vault_lock` | `true` | Lock the DR vault |
| `lock_grace_days` | `5` | Days before the lock becomes permanent (AWS minimum 3) |
| `data_volume_size` | `1` | GiB of the attached volume |

## Cost (us-east-1 / us-west-2, approximate)

| Item | Monthly |
|---|---|
| 8 GiB gp3 root volume | $0.64 |
| 1 GiB gp3 data volume | $0.08 |
| Primary vault storage (~1.5 GB, billed on used blocks) | ~$0.08 |
| DR vault storage (~1.2 GB) | ~$0.06 |
| Cross-region transfer ($0.02/GB, mostly the first copy) | ~$0.03 |
| Instance, stopped | $0.00 |
| **Total** | **~$0.90 (about ₹87)** |

Running the instance adds $7.59/month. No public IP is assigned, which avoids
another $3.65/month. AWS Backup charges nothing per job.

## Verification status

No Terraform binary was available, so `terraform validate` and `terraform plan`
have **not** been run. The file parses as valid HCL, all references resolve, and
the vault, vault lock and plan argument names were checked against the provider
docs. Read the plan before applying.
