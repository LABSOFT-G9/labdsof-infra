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
| Database AMI | newest build (`"*"`) | pinned version (`1.0.0`), changed only by a PR |
| Instance | `t3.micro` | `t3.small` |
| Data volume | 10 GiB | 20 GiB |
| Database subnet | public subnet, outbound-only public IP, no NAT or endpoint cost | private subnet with SSM interface endpoints (billed per hour) |
| Termination protection | off | on |
| Backup retention | 7 days | 30 days |
| Backup Object Lock | off | 14 days, governance mode |
| `terraform destroy` deletes non-empty buckets | yes | no |

In both, MySQL (3306) is reachable only from the application host's security group, the exporter (9104) only from monitoring groups, and no SSH port is open; administration goes through SSM Session Manager.

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

1. **State bucket and GitHub access** (admin credentials, local state): creates the state bucket, the GitHub OIDC provider and the roles `bmc-github-plan`, `bmc-github-apply-dev`, `bmc-github-apply-prod`.
   ```
   cd bootstrap && terraform init && terraform apply
   ```
   Then set the GitHub settings below from its outputs.
2. **Database secrets** for each environment, as `SecureString` parameters `root_password`, `backup_password`, `exporter_password` under `/bmc/<env>/database/` (runbook, "Secrets").
3. **AMI**:
   ```
   packer init ami/database && packer build -var version=1.0.0 ami/database
   ```
4. **Environments**: from then on through pull requests and CI (below). Locally, for a plan only:
   ```
   cd environments/dev
   terraform init -backend-config="bucket=bmc-terraform-state-<account-id>"
   terraform plan
   ```

Terraform ≥ 1.10 (S3 state locking without DynamoDB), AWS provider 6.x, Packer ≥ 1.11. CI uses Terraform 1.17.2 and Packer 1.16.2.

## CI/CD

| Trigger | Lint | Init + plan (dev, prod) | Apply dev | Apply prod |
|---|---|---|---|---|
| Pull request (any branch into `main`) | ✓ | ✓ | – | – |
| Merge to `main` | ✓ | ✓ | ✓ if the dev plan has changes | ✓ if the prod plan has changes, after dev succeeded, **after approval** |

- **Lint** (no AWS access): `terraform fmt`, `terraform validate` and TFLint for `environments/dev`, `environments/prod` and `bootstrap`; `packer fmt` and `packer validate`; ShellCheck.
- **Plan** (`.github/workflows/terraform.yml`, role `bmc-github-plan`): read-only, cannot read bucket objects or secret values. The plan is shown in the job summary and saved as an artifact for one day.
- **Apply** (same workflow, in the GitHub environment `dev` or `prod`, role `bmc-github-apply-<env>`): applies exactly the plan saved earlier in the same run; if the state changed in between, Terraform refuses and nothing changes.
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
| Environment `dev` | variable `AWS_APPLY_ROLE_ARN` | ARN of `bmc-github-apply-dev` |
| Environment `dev` | deployment branches | `main` only |
| Environment `prod` | variable `AWS_APPLY_ROLE_ARN` | ARN of `bmc-github-apply-prod` |
| Environment `prod` | deployment branches | `main` only |
| Environment `prod` | required reviewers | team `maintainers`, prevent self-review |
| Ruleset `main-review` | required status check | `ci-required` |

The `main`-only deployment branches matter: the apply roles trust any job running in that GitHub environment.

## Not here yet

- The application host and its module (US-17), and how it deploys the images from the application repository (DEC-12 linking options).
- The AMI build pipeline (Packer in CI).
- Monitoring targets and alerts (US-20).

## Rules

See [AGENTS.md](AGENTS.md). In short: reviewed PRs only, no secrets in Git or in Terraform variables, every change planned before it is applied, and nothing claimed as deployed without evidence.
