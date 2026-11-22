# Architecture

How BMC runs on AWS (dev; prod will copy it). Each diagram is titled and every icon, group and arrow is named; the numbered arrows are explained in the table under the diagram. A number and its arrow share a colour; grey lines only connect things on the same path.

Source of the images: [`diagrams/generate.py`](diagrams/generate.py) places every component on a grid and draws every arrow along a fixed path (icons from the Python `diagrams` package; writes `.svg` and `.png`). Change the script, not the images.

## 1. Overview

![Overview](diagrams/overview.png)

| Hosts | Address | What runs there |
|---|---|---|
| Edge (public subnet) | public IP, changes on stop/start | NAT for the private subnet; forwards 80/443 to the app host. No app code, no secrets |
| App | 10.10.1.10 | Traefik + the service containers (Docker Compose) |
| Database | 10.10.1.30 | MySQL 8.4 on its own EBS volume (kept when the host is replaced) |
| Monitoring | 10.10.1.20 | Prometheus, Loki, Grafana |

| Step | What happens |
|---|---|
| 1 | Users reach the edge host's public IP through the internet gateway. |
| 2 | The edge forwards ports 80/443 to Traefik on the app host, which routes to the services. |
| 3 | The services use MySQL on the database host (one database and user per service). |
| 4 | Private hosts reach the internet (image pulls, updates) only through the edge host's NAT. Nothing from the internet can reach them. |
| 5 | S3 traffic goes through the VPC gateway endpoint, not the internet: database backups to the backups bucket, attachments for the app. |
| 6 | Secrets live in Parameter Store, and each host may read only what it needs: the database host its own path, the app host the service database passwords (`/bmc/dev/database/users/*`), the monitoring host Grafana's password. |

Metrics and logs from every host go to the monitoring host (§4). The only way into a host is Systems Manager; no SSH port is open anywhere (§5).

## 2. Infrastructure changes (this repository)

![Infrastructure pipeline](diagrams/infra-pipeline.png)

| Step | What happens |
|---|---|
| 1 | A PR is merged into `main`. |
| 2 | The CI workflow starts: lint first. |
| 3 | Terraform plans dev and prod, reading the current state from the S3 state bucket. |
| 4 | A maintainer approves the apply ("Review deployments"); nothing changes in AWS without it. |
| 5 | Terraform signs in with the `bmc-ci` access key, which can only assume a role (STS). |
| 6 | As the `bmc-admin` role, limited by a permissions boundary, Terraform creates or changes the resources. |

Manual actions (Run workflow): apply, destroy, stop, start.

## 3. Application deploy (app repository)

![Application deploy](diagrams/app-deploy.png)

| Step | What happens |
|---|---|
| 1 | A PR is merged into `main` of LABDSOF_G9A. |
| 2 | Each service image is built, scanned (Trivy), signed (cosign) and pushed to GHCR as `dev-<commit>`. |
| 3 | The `bmc-deploy-dev` key may only send Run Command to the dev app host. |
| 4 | Run Command copies `compose.yaml` to the app host and runs `bmc-app-deploy <tag>`. |
| 5 | The deploy script reads the database passwords from Parameter Store. |
| 6 | The app host pulls the images from GHCR through the edge NAT and restarts the containers. |
| 7 | ZAP scans the site through the edge host's public IP (DAST). |

## 4. Metrics and logs

![Observability](diagrams/observability.png)

| Step | What happens |
|---|---|
| 1 | Grafana Alloy on every host pushes metrics to Prometheus (port 9090), including MySQL metrics. Kept 7 days. |
| 2 | Alloy pushes system and Docker logs to Loki (port 3100). Kept 7 days. |
| 3 | Grafana reads both. |
| 4 | Grafana is not public: open it with SSM port forwarding to `localhost:3000`. Password: `/bmc/dev/monitoring/grafana_admin_password`. |

## 5. Administration

![Admin access](diagrams/admin-access.png)

| Step | What happens |
|---|---|
| 1 | A shell on any host: SSM Session Manager (`aws ssm start-session`). |
| 2 | Configuration: run Ansible (`ansible/site.yml`), hosts found by their EC2 tags. |
| 3 | For each connection Ansible pushes a temporary SSH key with EC2 Instance Connect (valid 60 s). |
| 4 | SSH runs inside the SSM session (`ansible/ssm-ssh-proxy.sh`), so no port 22 is open. |

## 6. Database image

![Database image](diagrams/database-image.png)

| Step | What happens |
|---|---|
| 1 | Packer (`ami/database`) starts a temporary build host in the private subnet. |
| 2 | Ansible configures it through Session Manager (MySQL 8.4, Alloy, backup job). |
| 3 | Packer saves it as an AMI (`bmc-database-<version>`) and removes the build host. |
| 4 | Terraform starts the database host from that AMI, with the data on a separate EBS volume. |
| 5 | On every boot the host reads its passwords from Parameter Store (created by hand before the first apply, see the runbook) and creates or updates the databases and users. |

Details: [runbooks/database.md](runbooks/database.md).
