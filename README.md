# labdsof-infra

Infrastructure for **BMC — Building Maintenance Coordinator** (ISEP LABDSOF 26/27). The application, its backlog, ADRs and the CI that builds the service images live in [LABSOFT-G9/LABDSOF_G9A](https://github.com/LABSOFT-G9/LABDSOF_G9A). This repository holds what runs underneath:

- AWS resources as Terraform, written once as **internal modules** and used by every **environment**
- the database host image (**AMI**), built with Packer
- runbooks

Issues are tracked in the application repository (US-17 [#70](https://github.com/LABSOFT-G9/LABDSOF_G9A/issues/70), dev [#83](https://github.com/LABSOFT-G9/LABDSOF_G9A/issues/83), prod [#84](https://github.com/LABSOFT-G9/LABDSOF_G9A/issues/84)); reference them from PRs here with `Refs LABSOFT-G9/LABDSOF_G9A#N`.

## Layout

```
modules/                 internal modules, no environment-specific values
  network/               VPC, public + private subnet, S3 gateway endpoint, optional SSM endpoints
  storage/               S3 buckets: attachments and backups (private, encrypted, versioned, lifecycle)
  database/              EC2 database host from the AMI, encrypted data volume, IAM role, security group
environments/
  dev/                   calls the modules with dev values (terraform.tfvars)
  prod/                  the same modules with prod values
bootstrap/               one-time: the S3 bucket for Terraform state, the CI user and the bmc-admin role
ami/database/            Packer template, hardening and install scripts, compose.yaml, systemd units
docs/runbooks/           operating procedures
```

Each environment has its own state file (`<env>/terraform.tfstate` in the state bucket) and its own resources, all named `bmc-<env>-…`. A module change reaches both environments; a value change in one `terraform.tfvars` affects only that environment.

## Environments

| Setting | dev | prod |
|---|---|---|
| VPC | `10.10.0.0/16` | `10.20.0.0/16` |
| Database host | off for now (`database_enabled = false`) | off for now |
| Database AMI | newest build (`"*"`) | pinned version (`1.0.0`), changed only by a PR |
| Instance | `t3.micro` | `t3.small` |
| Data volume | 10 GiB | 10 GiB |
| Database subnet | public subnet, outbound-only public IP, no NAT or endpoint cost | private subnet with SSM interface endpoints (billed per hour) |
| Backup retention | 7 days | 30 days |
| Teardown | one step (`destroy`) | one step (`destroy`), after approval |

In both, MySQL (3306) is reachable only from the application host's security group, the exporter (9104) only from monitoring groups, and no SSH port is open; administration goes through SSM Session Manager.

Both environments are short-lived: dev is created to test the setup and destroyed afterwards; prod is created later, only to show a promotion, and destroyed after the showcase. That is why neither has termination protection or Object Lock, and their buckets can be deleted while not empty. For a long-lived prod, set `deletion_protection = true`, `force_destroy_buckets = false` and `backup_lock_days` above 0 in `environments/prod/terraform.tfvars` (the lock needs a new backups bucket).

## Lifecycle: create, test, destroy

1. **Create**: merge to `main`; CI plans and applies dev. Prod only when it is wanted: push a release tag on `main` (CI/CD below), and it applies after approval.
2. **Test**: runbook checks (Session Manager, MySQL up, a manual backup lands in S3, a restore).
3. **Destroy**: Actions → CI → Run workflow, choose `dev` (run it on `main`) or `prod` (run it on a release tag). It shows the destroy plan in the summary and removes everything in that environment, including the attachments and backups buckets. `prod` waits for approval.
4. **Clean up what Terraform does not own** (costs cents, but adds up):
   - old AMIs: deregister them and delete their snapshots (EC2 → AMIs, EC2 → Snapshots);
   - SSM parameters `/bmc/<env>/database/*` (free; delete if the environment will not come back).
5. **Keep**: the bootstrap state bucket, `bmc-ci` and `bmc-admin` (free or cents), so the next create works without setup.

Until the next create, nothing in the environment costs anything.

## Database host

```
ami/database (Packer)  ->  AMI bmc-database-<version>  ->  modules/database (Terraform)  ->  EC2 + data volume
```

- The **AMI** contains Ubuntu 24.04 LTS, hardening, Docker, the MySQL 8.4 and mysqld_exporter images pinned by digest and already pulled, the bootstrap and backup scripts and their systemd units. It contains no configuration and no secret.
- **Terraform** starts the instance from the AMI and passes the configuration (environment, bucket, parameter path, data volume) through user data.
- At boot the host mounts the **data volume** (formatted only when empty), reads the **secrets from SSM Parameter Store** (`/bmc/<env>/database/*`) into memory (`/run/bmc`), and starts MySQL and the exporter.
- **Backups**: a nightly `mysqldump` of all databases, compressed, to `s3://bmc-<env>-backups-<account>/mysql/<env>/`. The host can only add objects there; the bucket's lifecycle rule rotates them.
- **Patching** means building a new AMI version and replacing the instance; the data volume is kept.

Details and procedures: [docs/runbooks/database.md](docs/runbooks/database.md).

## First-time setup (per AWS account)

1. **Bootstrap: state bucket and CI access** (admin credentials, for example `aws login` or AWS CloudShell). Creates the single state bucket, the IAM user `bmc-ci`, the role `bmc-admin` and the workload boundary. Its own state ends up in the same bucket:
   ```
   cd bootstrap
   mv backend.tf backend.tf.off && terraform init && terraform apply   # first run: local state
   mv backend.tf.off backend.tf
   terraform init -migrate-state -backend-config="bucket=$(terraform output -raw state_bucket)"
   ```
   Later runs: `terraform init -backend-config="bucket=bmc-terraform-state-<account-id>"`, then plan and apply. Then create the CI access key by hand, so that it is never in Terraform or its state, and store it straight in GitHub:
   ```
   aws iam create-access-key --user-name bmc-ci --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text \
     | { read -r id secret
         gh secret set AWS_ACCESS_KEY_ID --repo LABSOFT-G9/labdsof-infra --body "$id"
         gh secret set AWS_SECRET_ACCESS_KEY --repo LABSOFT-G9/labdsof-infra --body "$secret"; }
   ```
   Then set the GitHub settings below from the outputs. To rotate the key: create a new one the same way, check a CI run, then `aws iam delete-access-key --user-name bmc-ci --access-key-id <old id>` (a user has at most two keys).
2. **Environments** through pull requests and CI (below). The first deploy creates the network and the buckets; the database host stays off (`database_enabled = false`) until the database AMI exists.
3. **Later, for the database host**: the secrets (runbook, "Secrets"), the AMI (`packer init ami/database && packer build -var version=1.0.0 ami/database`), then `database_enabled = true` in a PR.

### State

One bucket, `bmc-terraform-state-<account-id>`, one folder per configuration:

| Folder | Configuration | Read and write |
|---|---|---|
| `bootstrap/` | `bootstrap/` | admins, by hand |
| `dev/` | `environments/dev` | CI (`bmc-admin`) |
| `prod/` | `environments/prod` | CI (`bmc-admin`) |

Versioned, encrypted, no public access, locked with S3 lock files (no DynamoDB), protected from `terraform destroy`.

Terraform ≥ 1.10, AWS provider 6.x, Packer ≥ 1.11. CI uses Terraform 1.17.2 and Packer 1.16.2.

## CI/CD

| Trigger | Lint | Plan | Apply |
|---|---|---|---|
| Pull request (any branch into `main`) | ✓ | dev and prod | – |
| Merge to `main` | ✓ | dev | dev, if the plan has changes |
| Release tag `vX.Y.Z` on a commit on `main` | ✓ | prod | prod, **after approval**, if the plan has changes |

Everything is in one workflow, `.github/workflows/ci.yml`; what triggered it decides how far it runs.

**Releasing to prod**: choose a commit on `main` that dev already runs, tag it and push the tag:

```
git fetch origin && git tag v1.0.0 origin/main && git push origin v1.0.0
```

A tag on a commit that is not on `main` fails in plan, before touching AWS. To change prod again, merge to `main`, check dev, and push a new tag (`v1.0.1`, …); never move or reuse a tag.

- **Lint** (no AWS access): `terraform fmt`, `terraform validate` and TFLint for `environments/dev`, `environments/prod` and `bootstrap`; `packer fmt` and `packer validate`; ShellCheck.
- **Plan** (job `plan`, one per environment, role `bmc-admin`): the plan is shown in the job summary and saved as an artifact for one day.
- **Apply** (job `apply`: dev on `main`, prod on a release tag, in the GitHub environment of the same name, role `bmc-admin`): applies exactly the plan saved earlier in the same run; if the state changed in between, Terraform refuses and nothing changes. The `prod` approval is asked even when the prod plan has no changes (the job then ends without touching AWS), because a GitHub environment gates a whole job.
- Pull requests from forks stop after lint (GitHub gives them no secrets).
- `ci-required` (lint and the plans) is the single check to require on `main`.
- The bootstrap configuration is never applied by CI.
- Not yet: the AMI build (`packer build`) in CI.

## GitHub settings

Values come from the outputs of `bootstrap/`. Only the two `AWS_*_KEY*` entries are secrets.

| Where | Name | Value |
|---|---|---|
| Repository secret | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | access key of `bmc-ci` (First-time setup) |
| Repository variable | `AWS_REGION` | `eu-north-1` |
| Repository variable | `TF_STATE_BUCKET` | `bmc-terraform-state-<account-id>` |
| Repository variable | `AWS_ROLE_ARN` | output `admin_role_arn` (`bmc-admin`) |
| Environment `dev` | deployment branches | `main` only |
| Environment `prod` | deployment branches and tags | tags `v*` only (no branches) |
| Ruleset on tags `v*` | restrict creations, updates, deletions | only maintainers may push, move or delete release tags |
| Environment `prod` | required reviewers | team `maintainers`, prevent self-review |
| Ruleset `main-review` | required status check | `ci-required` |

## AWS access

The AWS Organization this account belongs to denies, with a service control policy, creating an OIDC provider, IAM groups and console passwords. So CI cannot use GitHub OIDC, and people cannot get IAM users of their own. What `bootstrap/` creates instead:

| Identity | Used by | Can |
|---|---|---|
| IAM user `bmc-ci` | CI, every job, with its access key | only switch into `bmc-admin` |
| Role `bmc-admin` | CI (plan, apply, destroy), sessions of one hour | everything (AdministratorAccess) |
| Policy `bmc-workload-boundary` | workload roles such as `bmc-<env>-database` | at most Session Manager and the `bmc-*` buckets |

People sign in through the Organization's own access (`aws login`), not through anything created here.

What this means:

- **Anyone who can push a branch to this repository gets admin rights in the account**: the plan runs on pull requests with the same role, and a changed workflow can use the secrets. Keep write access to the repository to the team, review workflow changes, and protect `main`.
- `prod` is protected only by its GitHub environment (approval, release tags only) and the tag ruleset, not by AWS permissions.
- The access key does not expire: rotate it (First-time setup), and delete it at once if it may have leaked.

## Not here yet

- The application host and its module (US-17), and how it deploys the images from the application repository (DEC-12 linking options).
- The AMI build pipeline (Packer in CI).
- Monitoring targets and alerts (US-20).

## Rules

See [AGENTS.md](AGENTS.md). In short: reviewed PRs only, no secrets in Git or in Terraform variables, every change planned before it is applied, and nothing claimed as deployed without evidence.
