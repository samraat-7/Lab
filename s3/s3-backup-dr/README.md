# S3 bucket + AWS Backup + DR vault + Vault Lock

A bucket backed up daily to a primary vault, with every backup copied to a DR
vault in a second region. Only the DR vault gets a Vault Lock, with a 5-day
grace period. The primary vault is not locked.

| Piece | Where |
|---|---|
| S3 bucket (versioned) | us-east-1 |
| Primary vault | us-east-1 |
| DR vault | us-west-2 |
| Backup plan | daily 05:00 UTC, 7-day retention, copy to DR |
| Vault Lock | DR vault only: compliance mode, 5-day grace, min 1 / max 365 days |

## Run it

```powershell
aws sts get-caller-identity
terraform init
terraform plan -out tfplan
terraform apply tfplan
terraform output next_steps
```

**One manual step:** AWS Backup > Settings > Service opt-in > enable **S3**, in
both regions. Without it the plan is created but backs up nothing, with no error.

`terraform output next_steps` prints ready-made commands to run the first backup
and copy job now instead of waiting for 05:00 UTC.

## Read this about the lock

- Days 0 to 5 (grace period): the lock can still be removed with
  `aws backup delete-backup-vault-lock-configuration --backup-vault-name <dr-vault> --region us-west-2`.
- After day 5 it is permanent. Nobody can remove it, including the root user and AWS.
- A locked vault cannot be deleted while it holds recovery points. They expire
  after 7 days on their own, so `terraform destroy` works about 7 days after the
  last backup. Until then it fails partway.
- Just testing? `terraform apply -var="enable_vault_lock=false"` skips the lock.
- Every backup must have retention between 1 and 365 days or the vault rejects
  it. The plan checks this for you.

## Cost

An empty bucket costs nothing. Backup storage is about $0.05/GB-month in each
vault, and the cross-region copy pays $0.03/GB transfer once per copy. AWS Backup
charges nothing per job. Objects under 128 KB are billed as 128 KB.

## Verification status

No Terraform binary was available, so `terraform validate` and `terraform plan`
have **not** been run. The file parses as valid HCL; argument names for the vault
lock and vault were checked against the provider docs. Read the plan before applying.
