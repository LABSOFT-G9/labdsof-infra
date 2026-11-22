"""Draws the architecture diagrams in docs/diagrams (docs/architecture.md).

The images carry icons and step numbers only; every explanation is in the
Markdown next to them. Regenerate after an infrastructure change:

    python3 -m venv .venv && .venv/bin/pip install diagrams==0.24.4
    (needs Graphviz: apt install graphviz)
    cd docs/diagrams && ../../.venv/bin/python generate.py
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import EC2Ami, EC2Instance
from diagrams.aws.general import InternetAlt1, User, Users
from diagrams.aws.management import (
    SystemsManagerParameterStore,
    SystemsManagerRunCommand,
    SystemsManager,
)
from diagrams.aws.network import Endpoint, InternetGateway
from diagrams.aws.security import (
    IdentityAndAccessManagementIamAWSSts,
    IdentityAndAccessManagementIamLongTermSecurityCredential,
    IdentityAndAccessManagementIamPermissions,
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

# Group colours follow the AWS architecture icon guide: cloud, VPC, public
# and private subnet. No group has a title; the Markdown names them.
AWS = {"bgcolor": "#FFFFFF", "pencolor": "#232F3E", "penwidth": "2", "style": "rounded"}
VPC = {"bgcolor": "#F2F8EE", "pencolor": "#7AA116", "penwidth": "2", "style": "rounded"}
PUBLIC = {"bgcolor": "#E9F3E6", "pencolor": "#7AA116", "style": "rounded"}
PRIVATE = {"bgcolor": "#E6F2F8", "pencolor": "#00A4A6", "style": "rounded"}
HOST = {"bgcolor": "#FFFFFF", "pencolor": "#ED7100", "style": "dashed,rounded"}
EXTERNAL = {"bgcolor": "#F5F5F5", "pencolor": "#999999", "style": "dashed,rounded"}

GRAPH = {"splines": "spline", "pad": "0.4", "nodesep": "0.7", "ranksep": "1.0", "fontsize": "1", "label": ""}
NODE = {"fontsize": "1", "labelloc": "b", "height": "1.2"}


# One colour per step number, so each number visibly belongs to its arrow.
STEP_COLOURS = ["#D13212", "#1F6FEB", "#2DA44E", "#8250DF", "#BF8700",
                "#E36209", "#0E8A8A", "#C2185B"]


def step(number, **attrs):
    """An arrow whose only text is its step number, both in the step's colour."""
    colour = STEP_COLOURS[(number - 1) % len(STEP_COLOURS)]
    return Edge(label=f" {number} ", fontsize="20", fontcolor=colour, color=colour,
                penwidth="2.2", **attrs)


def diagram(filename, direction="LR"):
    return Diagram("", filename=filename, show=False, direction=direction,
                   graph_attr=GRAPH, node_attr=NODE, outformat="png")


_groups = 0


def group(attrs):
    """A titleless group. Graphviz merges clusters with the same name, so each
    gets a different number of spaces as its (invisible) name."""
    global _groups
    _groups += 1
    return Cluster(" " * _groups, graph_attr=attrs)


# 1. Overview: where everything runs and how a request flows. One arrow per
# kind of traffic; the Markdown says which hosts each applies to.
with diagram("overview"):
    users = Users("")
    internet = InternetAlt1("")
    with group(AWS):
        ssm = SystemsManager("")
        params = SystemsManagerParameterStore("")
        s3 = SimpleStorageServiceS3Bucket("")
        with group(VPC):
            igw = InternetGateway("")
            endpoint = Endpoint("")
            with group(PUBLIC):
                edge = EC2Instance("")
            with group(PRIVATE):
                with group(HOST):
                    traefik = Traefik("")
                    services = Docker("")
                with group(HOST):
                    mysql = Mysql("")
                    volume = ElasticBlockStoreEBSVolume("")
                with group(HOST):
                    prometheus = Prometheus("")
                    grafana = Grafana("")

    users >> step(1) >> igw >> edge
    edge >> step(2) >> traefik >> services
    services >> step(3) >> mysql
    mysql - volume
    [services, mysql] >> step(4) >> prometheus
    prometheus - grafana
    services >> step(5, style="dashed") >> edge
    igw >> Edge(style="dashed") >> internet
    mysql >> step(6, style="dashed") >> endpoint >> s3
    services >> step(7, style="dotted") >> params
    ssm >> step(8, style="dotted") >> services


# 2. Infrastructure pipeline: merge -> plan -> approval -> apply.
with diagram("infra-pipeline"):
    dev = User("")
    approver = User("")
    with group(EXTERNAL):
        repo = Github("")
        actions = GithubActions("")
        key = IdentityAndAccessManagementIamLongTermSecurityCredential("")
    with group(AWS):
        sts = IdentityAndAccessManagementIamAWSSts("")
        role = IdentityAndAccessManagementIamRole("")
        boundary = IdentityAndAccessManagementIamPermissions("")
        state = SimpleStorageServiceS3Bucket("")
        with group(VPC):
            hosts = EC2Instance("")
    tf = Terraform("")

    dev >> step(1) >> repo >> step(2) >> actions
    actions >> step(3) >> tf >> state
    approver >> step(4) >> actions
    actions - key
    key >> step(5) >> sts >> role
    role - boundary
    role >> step(6) >> tf
    tf >> step(7) >> hosts


# 3. Application deploy: merge in the app repository -> dev.
with diagram("app-deploy"):
    dev = User("")
    scanner = User("")
    with group(EXTERNAL):
        repo = Github("")
        actions = GithubActions("")
        registry = Docker("")
        key = IdentityAndAccessManagementIamLongTermSecurityCredential("")
    with group(AWS):
        run = SystemsManagerRunCommand("")
        params = SystemsManagerParameterStore("")
        with group(VPC):
            with group(PUBLIC):
                edge = EC2Instance("")
            with group(PRIVATE):
                with group(HOST):
                    app = EC2Instance("")
                    traefik = Traefik("")

    dev >> step(1) >> repo >> actions
    actions >> step(2) >> registry
    actions - key
    key >> step(3) >> run >> step(4) >> app
    app >> step(5) >> params
    app >> step(6, style="dashed") >> edge >> registry
    actions >> step(7) >> scanner >> edge >> traefik


# 4. Metrics and logs.
with diagram("observability"):
    admin = User("")
    with group(AWS):
        ssm = SystemsManager("")
        with group(VPC):
            with group(PUBLIC):
                edge = EC2Instance("")
            with group(PRIVATE):
                app = EC2Instance("")
                db = EC2Instance("")
                with group(HOST):
                    prometheus = Prometheus("")
                    loki = Loki("")
                    grafana = Grafana("")

    sources = [edge, app, db]
    sources >> step(1) >> prometheus
    sources >> step(2) >> loki
    [prometheus, loki] >> step(3) >> grafana
    admin >> step(4) >> ssm >> grafana


# 5. Administration: no SSH port, no keys kept.
with diagram("admin-access"):
    admin = User("")
    ansible = Ansible("")
    with group(AWS):
        ssm = SystemsManager("")
        connect = IdentityAndAccessManagementIamTemporarySecurityCredential("")
        with group(VPC):
            with group(PUBLIC):
                edge = EC2Instance("")
            with group(PRIVATE):
                app = EC2Instance("")
                db = EC2Instance("")
                mon = EC2Instance("")

    hosts = [edge, app, db, mon]
    admin >> step(1) >> ssm >> hosts
    admin >> step(2) >> ansible >> step(3) >> connect
    ansible >> step(4) >> ssm


# 6. Database image (Packer + Ansible) and the database host.
with diagram("database-image"):
    admin = User("")
    ansible = Ansible("")
    tf = Terraform("")
    with group(AWS):
        ssm = SystemsManager("")
        ami = EC2Ami("")
        params = SystemsManagerParameterStore("")
        with group(VPC):
            with group(PRIVATE):
                builder = EC2Instance("")
                with group(HOST):
                    db = EC2Instance("")
                    volume = ElasticBlockStoreEBSVolume("")

    admin >> step(1) >> builder
    ansible >> step(2) >> ssm >> builder
    builder >> step(3) >> ami
    tf >> step(4) >> db
    ami >> db
    db - volume
    db >> step(5) >> params
