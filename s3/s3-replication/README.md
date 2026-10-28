# S3 replication: cross-region and same-region

One source bucket that copies every new object to two other buckets:

| Bucket | Region (default) | Type |
|---|---|---|
| source | us-east-1 | where you upload |
| crr | us-west-2 | cross-region replica (CRR) |
| srr | us-east-1 | same-region replica (SRR) |

Runs with no edits.

## Run it

```powershell
aws sts get-caller-identity
terraform init
terraform plan -out tfplan
terraform apply tfplan
```

Change regions only if you want to: `terraform apply -var="replica_region=eu-west-1"`.

## Test it

```powershell
terraform output test_commands
```

Paste the printed lines into PowerShell. Replication status goes from PENDING to
COMPLETED, usually within a few minutes. The same-region copy normally appears
first.

## Things to know

- **Only objects uploaded after apply are copied.** Replication ignores anything
  that existed before the rule. Copying existing objects needs an S3 Batch
  Operations replication job (console: save the rule, answer Yes to
  "Replicate existing objects?"). A Batch job costs $0.25 per job.
- Versioning is on for all three buckets. Replication will not save without it.
- Public access is blocked on all three buckets, and objects are encrypted with SSE-S3.
- Deletes: delete markers are replicated, but permanent version deletes are not.
  Deleting a version in the source does not remove it from the replicas.

## Cost

Empty buckets cost nothing. Per GB stored, expect about $0.023/GB-month in each
bucket, so 3 copies cost roughly 3x. Cross-region copies also pay about $0.02/GB
transfer, and every replicated object pays a small replication request fee
($0.005 per 1,000).

## Teardown

```powershell
terraform destroy
```

`force_destroy = true` is set, so buckets are emptied automatically, versions included.

## Verification status

No Terraform binary was available when this was written, so `terraform validate`
and `terraform plan` have **not** been run. The file parses as valid HCL. Read
the plan before applying.
