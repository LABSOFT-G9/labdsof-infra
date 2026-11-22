"""Draws the architecture diagrams in docs/diagrams (docs/architecture.md).

Every diagram has a title, every icon and group a name, and every arrow a
step number with a short label; the tables in architecture.md explain each
step. Regenerate after an infrastructure change:

    python3 -m venv .venv && .venv/bin/pip install diagrams==0.24.4
    (needs Graphviz: apt install graphviz)
    cd docs/diagrams && ../../.venv/bin/python generate.py
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import EC2Ami, EC2Instance
from diagrams.aws.general import InternetAlt1, User, Users
from diagrams.aws.management import (
    SystemsManager,
    SystemsManagerParameterStore,
    SystemsManagerRunCommand,
)
from diagrams.aws.network import Endpoint, InternetGateway
from diagrams.aws.security import (
    IdentityAndAccessManagementIamAWSSts,
    IdentityAndAccessManagementIamLongTermSecurityCredential,
    IdentityAndAccessManagementIamRole,
    IdentityAndAccessManagementIamTemporarySecurityCredential,
)
from diagrams.aws.storage import ElasticBlockStoreEBSVolume, SimpleStorageServiceS3Bucket
from diagrams.onprem.ci import GithubActions
from diagrams.onprem.container import Docker
from diagrams.onprem.database import Mysql
from diagrams.onprem.iac import Ansible, Terraform
from diagrams.onprem.logging import Loki
from diagrams.onprem.monitoring import Grafana, Prometheus
from diagrams.onprem.network import Traefik
from diagrams.onprem.vcs import Github

# Group colours follow the AWS architecture icon guide.
FONT = {"fontname": "Helvetica", "fontsize": "15", "labeljust": "l"}
AWS = {**FONT, "bgcolor": "#FFFFFF", "pencolor": "#232F3E", "penwidth": "2", "style": "rounded"}
VPC = {**FONT, "bgcolor": "#F7FBF2", "pencolor": "#7AA116", "penwidth": "2", "style": "rounded"}
PUBLIC = {**FONT, "bgcolor": "#E9F3E6", "pencolor": "#7AA116", "style": "rounded"}
PRIVATE = {**FONT, "bgcolor": "#E6F2F8", "pencolor": "#00A4A6", "style": "rounded"}
HOST = {**FONT, "bgcolor": "#FFFFFF", "pencolor": "#ED7100", "style": "dashed,rounded"}
GITHUB = {**FONT, "bgcolor": "#F5F5F5", "pencolor": "#6E7781", "style": "dashed,rounded"}

GRAPH = {"fontname": "Helvetica-Bold", "fontsize": "26", "labelloc": "t",
         "pad": "0.5", "nodesep": "0.8", "ranksep": "1.1", "splines": "spline"}
NODE = {"fontname": "Helvetica", "fontsize": "13"}

# One colour per step, so a number and its arrow clearly belong together.
STEP_COLOURS = ["#D13212", "#1F6FEB", "#2DA44E", "#8250DF", "#BF8700",
                "#E36209", "#0E8A8A", "#C2185B"]


def step(number, text, **attrs):
    """An arrow labelled '<number>. <text>' in the step's colour."""
    colour = STEP_COLOURS[(number - 1) % len(STEP_COLOURS)]
    return Edge(label=f"{number}. {text}", fontname="Helvetica-Bold", fontsize="13",
                fontcolor=colour, color=colour, penwidth="2.2", **attrs)


def line():
    """A plain connector (same host, or the continuation of a step)."""
    return Edge(color="#8C8C8C", penwidth="1.2")


def diagram(title, filename, direction="LR"):
    return Diagram(title, filename=filename, show=False, direction=direction,
                   graph_attr=GRAPH, node_attr=NODE, outformat="png")


def group(title, attrs):
    return Cluster(title, graph_attr=attrs)


# 1. Overview ------------------------------------------------------------------
with diagram("BMC on AWS: dev environment", "overview"):
    users = Users("Users\n(browser)")
    ghcr = InternetAlt1("Internet\n(GHCR, updates)")

    with group("AWS account · eu-north-1", AWS):
        with group("Regional services", AWS):
            ssm = SystemsManager("Systems Manager\n(admin access)")
            params = SystemsManagerParameterStore("Parameter Store\n(secrets)")
            s3 = SimpleStorageServiceS3Bucket("S3\n(backups, attachments)")

        with group("VPC bmc-dev · 10.10.0.0/16 · eu-north-1a", VPC):
            igw = InternetGateway("Internet\ngateway")
            s3_endpoint = Endpoint("S3 gateway\nendpoint")

            with group("Public subnet · 10.10.0.0/24", PUBLIC):
                edge = EC2Instance("Edge host\nNAT + port forward")

            with group("Private subnet · 10.10.1.0/24", PRIVATE):
                with group("App host · 10.10.1.10", HOST):
                    traefik = Traefik("Traefik")
                    services = Docker("Services\n(client, issue,\ndispatch, …)")
                with group("Database host · 10.10.1.30", HOST):
                    mysql = Mysql("MySQL 8.4")
                    volume = ElasticBlockStoreEBSVolume("Data volume\n(EBS)")
                with group("Monitoring host · 10.10.1.20", HOST):
                    prometheus = Prometheus("Prometheus\n+ Loki")
                    grafana = Grafana("Grafana")

    users >> step(1, "HTTP 80/443") >> igw >> line() >> edge
    edge >> step(2, "forward") >> traefik >> line() >> services
    services >> step(3, "SQL 3306") >> mysql
    mysql - line() - volume
    [services, mysql] >> step(4, "metrics + logs") >> prometheus
    prometheus - line() - grafana
    services >> step(5, "outbound via NAT", style="dashed") >> edge
    igw >> Edge(color="#8C8C8C", style="dashed") >> ghcr
    mysql >> step(6, "backups", style="dashed") >> s3_endpoint >> line() >> s3
    services >> step(7, "read secrets", style="dotted") >> params
    ssm >> step(8, "sessions, Run Command", style="dotted") >> services


# 2. Infrastructure pipeline ---------------------------------------------------
with diagram("Infrastructure changes: merge → plan → approve → apply", "infra-pipeline"):
    developer = User("Developer")
    approver = User("Maintainer\n(approver)")

    with group("GitHub · labdsof-infra", GITHUB):
        repo = Github("main branch")
        actions = GithubActions("CI workflow\nlint · plan · apply")
        key = IdentityAndAccessManagementIamLongTermSecurityCredential("bmc-ci\naccess key")
    terraform = Terraform("Terraform")

    with group("AWS account · eu-north-1", AWS):
        sts = IdentityAndAccessManagementIamAWSSts("STS\nAssumeRole")
        role = IdentityAndAccessManagementIamRole("bmc-admin role\n(permissions boundary)")
        state = SimpleStorageServiceS3Bucket("Terraform state\n(S3)")
        with group("VPC bmc-dev", VPC):
            hosts = EC2Instance("Network, hosts,\nIAM, buckets")

    developer >> step(1, "merge PR") >> repo
    repo >> step(2, "trigger") >> actions
    actions >> step(3, "plan dev + prod") >> terraform
    terraform >> line() >> state
    approver >> step(4, "Review deployments") >> actions
    actions >> line() >> key
    key >> step(5, "assume role") >> sts >> line() >> role
    role >> step(6, "apply") >> terraform
    terraform >> step(7, "create / change") >> hosts


# 3. Application deploy --------------------------------------------------------
with diagram("Application deploy to dev", "app-deploy"):
    developer = User("Developer")

    with group("GitHub · LABDSOF_G9A", GITHUB):
        repo = Github("main branch")
        actions = GithubActions("dev.yml + deploy.yml")
        registry = Docker("GHCR\nlabdsof-<service>")
        key = IdentityAndAccessManagementIamLongTermSecurityCredential("bmc-deploy-dev\naccess key")
        zap = GithubActions("ZAP scan")

    with group("AWS account · eu-north-1", AWS):
        run_command = SystemsManagerRunCommand("SSM Run Command")
        params = SystemsManagerParameterStore("Parameter Store\n(DB passwords)")
        with group("VPC bmc-dev", VPC):
            with group("Public subnet", PUBLIC):
                edge = EC2Instance("Edge host")
            with group("Private subnet", PRIVATE):
                with group("App host", HOST):
                    deploy = EC2Instance("bmc-app-deploy")
                    traefik = Traefik("Traefik +\nservices")

    developer >> step(1, "merge PR") >> repo >> line() >> actions
    actions >> step(2, "build · scan · sign · push") >> registry
    actions >> line() >> key
    key >> step(3, "send command") >> run_command
    run_command >> step(4, "run deploy <tag>") >> deploy
    deploy >> step(5, "read passwords") >> params
    deploy >> step(6, "pull images (via NAT)", style="dashed") >> edge >> line() >> registry
    deploy >> line() >> traefik
    actions >> line() >> zap
    zap >> step(7, "DAST scan") >> edge >> line() >> traefik


# 4. Metrics and logs ------------------------------------------------------------
with diagram("Metrics and logs", "observability"):
    admin = User("Admin")

    with group("AWS account · eu-north-1", AWS):
        ssm = SystemsManager("Session Manager\nport forwarding")
        with group("VPC bmc-dev", VPC):
            with group("Public subnet", PUBLIC):
                edge = EC2Instance("Edge host\n+ Alloy")
            with group("Private subnet", PRIVATE):
                app = EC2Instance("App host\n+ Alloy")
                db = EC2Instance("Database host\n+ Alloy")
                with group("Monitoring host", HOST):
                    prometheus = Prometheus("Prometheus :9090\n(7 days)")
                    loki = Loki("Loki :3100\n(7 days)")
                    grafana = Grafana("Grafana\nlocalhost:3000")

    for host in (edge, app, db):
        host >> step(1, "metrics") >> prometheus
        host >> step(2, "logs") >> loki
    prometheus >> step(3, "query") >> grafana
    loki >> step(3, "query") >> grafana
    admin >> step(4, "open Grafana") >> ssm >> line() >> grafana


# 5. Administration ---------------------------------------------------------------
with diagram("Administration: no SSH port, no stored keys", "admin-access"):
    admin = User("Admin")
    ansible = Ansible("Ansible\nsite.yml")

    with group("AWS account · eu-north-1", AWS):
        ssm = SystemsManager("Session Manager")
        connect = IdentityAndAccessManagementIamTemporarySecurityCredential("EC2 Instance Connect\n(60 s SSH key)")
        with group("VPC bmc-dev", VPC):
            with group("Public subnet", PUBLIC):
                edge = EC2Instance("Edge host")
            with group("Private subnet", PRIVATE):
                app = EC2Instance("App host")
                db = EC2Instance("Database host")
                mon = EC2Instance("Monitoring host")

    admin >> step(1, "shell") >> ssm
    admin >> step(2, "configure") >> ansible
    ansible >> step(3, "push temporary key") >> connect
    ansible >> step(4, "SSH inside SSM session") >> ssm
    ssm >> line() >> [edge, app, db, mon]


# 6. Database image -----------------------------------------------------------------
with diagram("Database image and host", "database-image"):
    admin = User("Admin\n(packer build)")
    ansible = Ansible("Ansible\ndatabase-image.yml")
    terraform = Terraform("Terraform")

    with group("AWS account · eu-north-1", AWS):
        ssm = SystemsManager("Session Manager")
        ami = EC2Ami("AMI\nbmc-database-<version>")
        params = SystemsManagerParameterStore("Parameter Store\n(DB passwords)")
        with group("VPC bmc-dev · private subnet", PRIVATE):
            builder = EC2Instance("Temporary\nbuild host")
            with group("Database host · 10.10.1.30", HOST):
                db = EC2Instance("Database host")
                volume = ElasticBlockStoreEBSVolume("Data volume\n(EBS)")

    admin >> step(1, "start build") >> builder
    ansible >> step(2, "configure") >> ssm >> line() >> builder
    builder >> step(3, "save image") >> ami
    terraform >> step(4, "launch") >> db
    ami >> line() >> db
    db - line() - volume
    db >> step(5, "read passwords at boot") >> params
