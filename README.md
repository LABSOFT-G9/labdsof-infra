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
bootstrap/               one-time: the S3 bucket for Terraform state
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

1. **Create**: merge to `main`; CI plans and applies dev (and prod after approval, once it is wanted).
2. **Test**: runbook checks (Session Manager, MySQL up, a manual backup lands in S3, a restore).
3. **Destroy**: Actions → CI → Run workflow on `main`, choose `dev` or `prod`. It shows the destroy plan in the summary and removes everything in that environment, including the attachments and backups buckets. `prod` waits for approval.
4. **Clean up what Terraform does not own** (costs cents, but adds up):
   - old AMIs: deregister them and delete their snapshots (EC2 → AMIs, EC2 → Snapshots);
   - SSM parameters `/bmc/<env>/database/*` (free; delete if the environment will not come back).
5. **Keep**: the bootstrap state bucket and the GitHub roles (free or cents), so the next create works without setup.

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

1. **Bootstrap: state bucket and IAM** (admin credentials, for example AWS CloudShell). Creates the single state bucket, the GitHub OIDC provider, the plan and deploy roles, the workload boundary, and the team roles, groups and users. Its own state ends up in the same bucket:
   ```
   cd bootstrap
   mv backend.tf backend.tf.off && terraform init && terraform apply   # first run: local state
   mv backend.tf.off backend.tf
   terraform init -migrate-state -backend-config="bucket=$(terraform output -raw state_bucket)"
   ```
   Later runs: `terraform init -backend-config="bucket=bmc-terraform-state-<account-id>"`, then plan and apply. Then set the GitHub settings below from the outputs.
2. **Environments** through pull requests and CI (below). The first deploy creates the network and the buckets; the database host stays off (`database_enabled = false`) until the database AMI exists.
3. **Later, for the database host**: the secrets (runbook, "Secrets"), the AMI (`packer init ami/database && packer build -var version=1.0.0 ami/database`), then `database_enabled = true` in a PR.

### State

One bucket, `bmc-terraform-state-<account-id>`, one folder per configuration:

| Folder | Configuration | Read and write |
|---|---|---|
| `bootstrap/` | `bootstrap/` | admins only |
| `dev/` | `environments/dev` | `bmc-deploy-dev`; `bmc-github-plan` reads and locks |
| `prod/` | `environments/prod` | `bmc-deploy-prod`; `bmc-github-plan` reads and locks |

Versioned, encrypted, no public access, locked with S3 lock files (no DynamoDB), protected from `terraform destroy`.

Terraform ≥ 1.10, AWS provider 6.x, Packer ≥ 1.11. CI uses Terraform 1.17.2 and Packer 1.16.2.

## CI/CD

| Trigger | Lint | Init + plan (dev, prod) | Apply dev | Apply prod |
|---|---|---|---|---|
| Pull request (any branch into `main`) | ✓ | ✓ | – | – |
| Merge to `main` | ✓ | ✓ | ✓ applies the dev plan if it has changes | ✓ after dev succeeded and **after approval**; applies the prod plan if it has changes |

Everything is in one workflow, `.github/workflows/ci.yml`; the branch decides how far it runs.

- **Lint** (no AWS access): `terraform fmt`, `terraform validate` and TFLint for `environments/dev`, `environments/prod` and `bootstrap`; `packer fmt` and `packer validate`; ShellCheck.
- **Plan** (job `plan`, one per environment, role `bmc-github-plan`): read-only, cannot read bucket objects or secret values. The plan is shown in the job summary and saved as an artifact for one day.
- **Apply** (job `apply`, only on `main`, dev then prod, in the GitHub environment `dev` or `prod`, role `bmc-deploy-<env>`): applies exactly the plan saved earlier in the same run; if the state changed in between, Terraform refuses and nothing changes. If dev fails, prod is cancelled. The `prod` approval is asked even when the prod plan has no changes (the job then ends without touching AWS), because a GitHub environment gates a whole job.
- Pull requests from forks stop after lint (GitHub gives them no OIDC token).
- `ci-required` (lint and both plans) is the single check to require on `main`.
- The bootstrap configuration is never applied by CI.
- Not yet: the AMI build (`packer build`) in CI.

## GitHub settings

Values come from the outputs of `bootstrap/`. None of them is a secret.

| Where | Name | Value |
|---|---|---|
| Repository variable | `AWS_REGION` | `eu-west-1` |
| Repository variable | `TF_STATE_BUCKET` | `bmc-terraform-state-<account-id>` |
| Repository variable | `AWS_PLAN_ROLE_ARN` | ARN of `bmc-github-plan` |
| Environment `dev` | variable `AWS_DEPLOY_ROLE_ARN` | ARN of `bmc-deploy-dev` |
| Environment `dev` | deployment branches | `main` only |
| Environment `prod` | variable `AWS_DEPLOY_ROLE_ARN` | ARN of `bmc-deploy-prod` |
| Environment `prod` | deployment branches | `main` only |
| Environment `prod` | required reviewers | team `maintainers`, prevent self-review |
| Ruleset `main-review` | required status check | `ci-required` |

The `main`-only deployment branches matter: the deploy roles trust any job running in that GitHub environment.

## AWS roles

All created by `bootstrap/` (applied once by an admin, by hand). IAM is free on the AWS free plan; IAM Identity Center is not available without upgrading, so people use plain IAM.

| Role | Used by | Can |
|---|---|---|
| `bmc-github-plan` | CI, every branch and PR | read-only; write only the state lock; no bucket contents, no secret values |
| `bmc-deploy-dev` | CI on `main`, GitHub environment `dev` | deploy (apply, destroy) **dev only**: EC2/VPC resources tagged `Environment=dev`, buckets `bmc-dev-*`, roles and instance profiles `bmc-dev-*` (with the workload boundary), its own state file, one region |
| `bmc-deploy-prod` | CI on `main`, GitHub environment `prod`, after approval | the same, for prod only |
| `bmc-admin` | people (switch role, MFA) | everything; emergencies only |
| `bmc-operator` | people (switch role, MFA) | view everything; start, stop, reboot BMC instances; Session Manager; read backups and logs. No creating or deleting infrastructure |
| `bmc-viewonly` | people (switch role, MFA) | view resources, settings, costs and metrics; no data, no secrets |

The deploy roles have no admin rights. Every role they create (for example `bmc-dev-database`) must carry the permissions boundary `bmc-workload-boundary` (SSM and the `bmc-*` buckets only), so a deploy role cannot create a more powerful role for itself; it can attach only AWS's `AmazonSSMManagedInstanceCore` policy, cannot remove a boundary, and cannot retag a resource into the other environment. When a new kind of resource is added and an apply fails with `AccessDenied`, add exactly the missing action to `bootstrap/github-oidc.tf` in a reviewed PR. These policies have not been run against AWS yet; the first dev apply is their test.

### Team access

Each person has an IAM user with no permissions of its own, in one group that decides which roles they may switch into (`team` in `bootstrap/team-access.tf`):

| User | Group | Can switch into |
|---|---|---|
| `martim` | `bmc-admin-users` | admin, operator, viewonly |
| `ricardo`, `pedro`, `afonso`, `sandro` | `bmc-viewonly-users` | viewonly |

Adding, removing or changing someone is a PR to that map, applied by an admin. First sign-in:

1. The admin creates a one-time console password for the user (IAM → Users → Security credentials → Enable console access, "must change at next sign-in") and sends it privately.
2. The person signs in at `https://<account-id>.signin.aws.amazon.com/console`, sets a new password (14+ characters) and assigns an MFA device to their own user.
3. They sign out and in again with MFA, then **Switch role**: account ID and role name (for example `bmc-operator`). Sessions last one hour.

No access keys for people; the root user has MFA and is not used day to day.

## Not here yet

- The application host and its module (US-17), and how it deploys the images from the application repository (DEC-12 linking options).
- The AMI build pipeline (Packer in CI).
- Monitoring targets and alerts (US-20).

## Rules

See [AGENTS.md](AGENTS.md). In short: reviewed PRs only, no secrets in Git or in Terraform variables, every change planned before it is applied, and nothing claimed as deployed without evidence.
