# labdsof-infra

Infrastructure for **BMC — Building Maintenance Coordinator** (ISEP LABDSOF 26/27). The application, its backlog, ADRs and the CI that builds the service images live in [LABSOFT-G9/LABDSOF_G9A](https://github.com/LABSOFT-G9/LABDSOF_G9A). This repository holds what runs underneath:

- AWS resources as Terraform, written once as **internal modules** and used by every **environment**
- the database host image (**AMI**), built with Packer and configured by Ansible
- runbooks

Issues are tracked in the application repository (US-17 [#70](https://github.com/LABSOFT-G9/LABDSOF_G9A/issues/70), dev [#83](https://github.com/LABSOFT-G9/LABDSOF_G9A/issues/83), prod [#84](https://github.com/LABSOFT-G9/LABDSOF_G9A/issues/84)); reference them from PRs here with `Refs LABSOFT-G9/LABDSOF_G9A#N`.

## Layout

```
modules/                 internal modules, no environment-specific values
  network/               VPC, public + private subnet, S3 gateway endpoint, optional SSM endpoints, locked default security group
  edge/                  the only public host: NAT for the private subnet, forwards 80/443 to the application host
  app/                   application host: plain EC2 in the private subnet, security group, IAM role
  monitoring/            monitoring host: EC2 in the private subnet for Prometheus and Grafana; accepts pushed metrics (9090)
  storage/               S3 buckets: attachments and backups (private, encrypted, versioned, lifecycle)
  database/              EC2 database host from the AMI, encrypted data volume, IAM role, security group
environments/
  dev/                   calls the modules with dev values (terraform.tfvars)
  prod/                  the same modules with prod values
bootstrap/               one-time: the S3 bucket for Terraform state, the CI user and the bmc-admin role
ami/database/            Packer template: builds the database image in dev's private subnet, configured by Ansible
ansible/                 Ansible: database-image.yml (image build), site.yml (running hosts over Session Manager); roles base, docker, database, app, monitoring, alloy
docs/runbooks/           operating procedures
```

Each environment has its own state file (`<env>/terraform.tfstate` in the state bucket) and its own resources, all named `bmc-<env>-…`. A module change reaches both environments; a value change in one `terraform.tfvars` affects only that environment.

## Environments

| Setting | dev | prod |
|---|---|---|
| VPC | `10.10.0.0/16` | `10.20.0.0/16` |
| Database host | on (`database_enabled = true`), image `bmc-database-1.0.0` | off for now |
| Database AMI | newest build (`"*"`) | pinned version (`1.0.0`), changed only by a PR |
| Database instance | `t3.small` (2 GiB: MySQL and the Alloy agent do not fit in 1 GiB) | `t3.small` |
| Data volume | 10 GiB | 10 GiB |
| Database subnet | private subnet, outbound through the edge host (fixed IP `10.10.1.30`) | not set up yet (dev first) |
| Backup retention | 7 days | 30 days |
| Teardown | one step (`destroy`) | one step (`destroy`), after approval |

In both, MySQL (3306) is reachable only from the application host's security group (MySQL metrics are read on the host by the Alloy agent), and no SSH port is open; administration goes through SSM Session Manager.

Both environments are short-lived: dev is created to test the setup and destroyed afterwards; prod is created later, only to show a promotion, and destroyed after the showcase. That is why neither has termination protection or Object Lock, and their buckets can be deleted while not empty. For a long-lived prod, set `deletion_protection = true`, `force_destroy_buckets = false` and `backup_lock_days` above 0 in `environments/prod/terraform.tfvars` (the lock needs a new backups bucket).

## Network (dev)

Prod gets the same layout once dev is settled. Software on the hosts is added case by case.

```
dev VPC 10.10.0.0/16, one availability zone (eu-north-1a)
├─ Public subnet  10.10.0.0/24  route 0.0.0.0/0 -> internet gateway
│    └─ Edge host  t3.micro, public IP (changes on stop/start). NAT for the private subnet;
│                  forwards TCP 80/443 to the application host
└─ Private subnet 10.10.1.0/24  route 0.0.0.0/0 -> edge host
     ├─ Application host  m7i-flex.large (8 GiB), 10.10.1.10, no public IP; plain server,
     │                    nothing installed yet
     ├─ Monitoring host   t3.small, 10.10.1.20, no public IP; plain server,
     │                    nothing installed yet (Prometheus, Loki, Grafana later)
     └─ Database host     t3.small, 10.10.1.30, from bmc-database-1.1.0
S3 gateway endpoint on both route tables (free)
```

- Web traffic: internet -> edge host :80/443 -> application host. The client's address is kept. Nothing answers yet: the application host has no software.
- The private hosts reach the internet only outbound, through the edge host's NAT; nothing on the internet can open a connection to them.
- Monitoring is push-based: an agent (Grafana Alloy) on every host sends metrics to Prometheus on the monitoring host (9090), and nothing else reaches it. Grafana listens on the monitoring host only and is reached through Session Manager port forwarding, not exposed.
- The edge host runs only the NAT and forwarding rules (nftables, `modules/edge/user-data.sh.tftpl`); no application code, no secrets.
- Edge, application and monitoring hosts: Amazon Linux 2023 (x86_64, image pinned in `terraform.tfvars`), IMDSv2 only, encrypted disks, administered through SSM Session Manager; no SSH port.
- The VPC's default security group has no rules, so anything launched without a security group has no network access.
- The account is on the AWS Free plan: only free-tier eligible instance types launch (eu-north-1: `t3.micro`, `t3.small`, `c7i-flex.large`, `m7i-flex.large`, `t4g.micro`, `t4g.small`); any other type fails at apply with `InvalidParameterCombination`.
- The account's default VPC in eu-north-1 (`172.31.0.0/16`, public subnets that hand out public IPs) was deleted on 2026-11-21, outside Terraform, so nothing can be launched there by accident. `aws ec2 create-default-vpc` recreates it if ever needed.

## Configuring the hosts (Ansible)

`ansible/site.yml` configures the running hosts of dev: Docker and Compose on the application and monitoring hosts, `/opt/bmc-app` for the application's Compose file, Prometheus and Grafana on the monitoring host, and the Alloy agent on every host (host metrics, container metrics where Docker runs, MySQL metrics on the database host). Hosts are found by their `Role` tag.

**How Ansible reaches the hosts: SSH tunnelled through Session Manager.** No port is open and no key stays on the hosts: `ansible/ssm-ssh-proxy.sh` pushes your public key to the host with EC2 Instance Connect (valid 60 seconds, enough to log in), then opens a Session Manager tunnel to its SSH port. Access is decided by your AWS login.

Needs, where you run it: AWS credentials, the Session Manager plugin, `ansible-core` 2.21 with `boto3` and `botocore`, and an SSH key that stays on your machine:

```
ssh-keygen -t ed25519 -f ~/.ssh/bmc_dev        # once; or point BMC_SSH_KEY at another key
cd ansible
ansible-galaxy collection install -r requirements.yml
ansible-inventory -i inventory/dev.aws_ec2.yml --graph     # edge, app, monitoring, database
ansible all -i inventory/dev.aws_ec2.yml -m ping
ansible-playbook -i inventory/dev.aws_ec2.yml site.yml
```

The same works for a plain shell (`ec2-user` on Amazon Linux, `ubuntu` on the database host):

```
ssh -i ~/.ssh/bmc_dev -o ProxyCommand="ansible/ssm-ssh-proxy.sh %h %r %p" ec2-user@<instance id>
```

### Grafana

```
aws ssm start-session --target <monitoring instance id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters portNumber=3000,localPortNumber=3000
```

Then open <http://localhost:3000>, user `admin`, password in Parameter Store `/bmc/dev/monitoring/grafana_admin_password` (`aws ssm get-parameter --with-decryption …`, on your own machine). Prometheus is already its data source; metrics carry the labels `host`, `role` and `environment`. Prometheus keeps 7 days.

## Application deploy

The application repository deploys to dev from its own pipeline (`deploy.yml`), with no SSH and no inbound access:

```
deploy job (LABSOFT-G9/LABDSOF_G9A, environment dev)
  1. signs in as the IAM user bmc-deploy-dev (bootstrap/deploy-access.tf)
  2. finds the dev application host (tags Environment=dev, Role=app) and the edge host's public IP (APP_URL)
  3. SSM Run Command on the application host:
       writes compose.yaml to /opt/bmc-app
       bmc-app-deploy <tag>   (ansible/roles/app)
  4. smoke check and ZAP against http://<edge IP>
```

`bmc-app-deploy <tag>` reads the service database users' passwords from Parameter Store (`/bmc/dev/database/users/*`) into `/run/bmc-app/deploy.env` (memory only, root only) as `<NAME>_DB_PASSWORD`, with `BMC_TAG`, `DB_HOST` and `DB_PORT`, then runs `docker compose pull` and `up -d`. The images are public in GHCR, so no registry login is needed.

`bmc-deploy-dev` can only run `AWS-RunShellScript` on instances tagged `Environment=dev` and `Role=app`, read its command results and list instances. Its access key is created by hand and stored only in the application repository's `dev` environment, never printed:

```
aws iam create-access-key --user-name bmc-deploy-dev --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text \
  | { read -r id secret
      gh secret set AWS_ACCESS_KEY_ID     --repo LABSOFT-G9/LABDSOF_G9A --env dev --body "$id"
      gh secret set AWS_SECRET_ACCESS_KEY --repo LABSOFT-G9/LABDSOF_G9A --env dev --body "$secret"; }
```

## Lifecycle: create, test, destroy

1. **Create**: merge to `main`. The run plans dev and prod, then each environment whose plan has changes waits for approval: open the run, read the plan in its summary, **Review deployments** → approve. dev applies first, prod only after dev succeeded. To apply without a new merge, use the button: Actions → CI → Run workflow on `main`, environment, action `apply`.
2. **Test**: runbook checks (Session Manager, MySQL up, a manual backup lands in S3, a restore).
2b. **Pause**: the button with action `stop` stops every instance of the environment: no instance hours are billed, the disks (and MySQL data) and buckets stay. `start` brings it back in a minute or two, the edge host first. The edge host's public IP changes on every start. While stopped, dev costs only its disks (about USD 6.70 a month).
3. **Destroy**: the button with action `destroy`. It shows the destroy plan in the summary and removes everything in that environment, including the attachments and backups buckets. `prod` waits for approval.
4. **Clean up what Terraform does not own** (costs cents, but adds up):
   - old AMIs: deregister them and delete their snapshots (EC2 → AMIs, EC2 → Snapshots);
   - SSM parameters `/bmc/<env>/database/*` (free; delete if the environment will not come back).
5. **Keep**: the bootstrap state bucket, `bmc-ci` and `bmc-admin` (free or cents), so the next create works without setup.

Until the next create, nothing in the environment costs anything.

## Database host

```
ami/database (Packer) + ansible/ (Ansible)  ->  AMI bmc-database-<version>  ->  modules/database (Terraform)  ->  EC2 + data volume
```

- The **AMI** contains Ubuntu 24.04 LTS, hardening, Docker, the MySQL 8.4 image pinned by digest and already pulled, the bootstrap and backup scripts and their systemd units. It contains no configuration and no secret.
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
3. **Later, for the database host**: the secrets (runbook, "Secrets"), the AMI (below), then `database_enabled = true` in a PR.

### Building the database image

Packer starts a temporary instance in **dev's private subnet** (dev must be applied first: network and edge host), reaches it through SSM Session Manager (no public IP, no open port) and lets Ansible configure it. Where you run it you need AWS credentials (`aws login`), Packer ≥ 1.11, `ansible-core` 2.21 (Python 3.12) and the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) for the AWS CLI.

```
packer init ami/database
packer build -var version=1.0.0 ami/database
```

The result is `bmc-database-1.0.0`. Takes about 10 minutes; the temporary instance and its security group and role are deleted at the end.

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
| **Merge to `main`** | ✓ | dev and prod | each environment **with changes**, after **approval**: dev first, prod only after dev succeeded |
| **Run workflow** button on `main` (environment, action) | ✓ | the chosen environment (a destroy plan for `destroy`) | apply or destroy it, if the plan has changes, after **approval** |
| **Run workflow** button, action `stop` / `start` | ✓ | – | stops or starts the environment's instances, after **approval** (start: edge host first) |

Everything is in one workflow, `.github/workflows/ci.yml`. Nothing changes in AWS without an approval: the apply job waits in the run with **Review deployments**, and the plan it will apply is in the run's summary. An environment whose plan has no changes gets no apply job and asks for nothing. The button is for destroying, or for applying without a new merge.

- **Lint** (no AWS access): `terraform fmt`, `terraform validate` and TFLint for `environments/dev`, `environments/prod` and `bootstrap`; `packer fmt` and `packer validate`; `ansible-lint` (26.11.0, with ansible-core 2.21.6); ShellCheck.
- **Plan** (job `plan`, one per environment, role `bmc-admin`): the plan is shown in the job summary and saved as an artifact for one day.
- **Changes** (job `changes`, on `main`): lists the environments whose plan has changes, dev before prod.
- **Apply** (job `apply`, one per listed environment, in the GitHub environment of the same name, role `bmc-admin`): waits for a required reviewer, then applies exactly the plan saved earlier in the same run; if the state changed in between, Terraform refuses and nothing changes. prod runs only after dev succeeded.
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
| Environment `prod` | deployment branches | `main` only |
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
- `prod` is protected only by its GitHub environment (approval, `main` only), not by AWS permissions.
- The access key does not expire: rotate it (First-time setup), and delete it at once if it may have leaked.

## Not here yet

- Software on the application host, and how it deploys the images from the application repository (DEC-12 linking options). The host itself is `modules/app`.
- The AMI build pipeline (Packer in CI).
- Monitoring targets and alerts (US-20).

## Rules

See [AGENTS.md](AGENTS.md). In short: reviewed PRs only, no secrets in Git or in Terraform variables, every change planned before it is applied, and nothing claimed as deployed without evidence.
