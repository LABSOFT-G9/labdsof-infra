"""Draws the architecture diagrams in docs/diagrams (docs/architecture.md).

Every component sits on a fixed grid and every arrow follows an explicit
right-angled path, so the layout stays clean and arrows do not cross. Icons
come from the `diagrams` package (AWS architecture icons and a few others).

Regenerate after an infrastructure change:

    python3 -m venv .venv && .venv/bin/pip install diagrams==0.24.4 cairosvg==2.8.2
    cd docs/diagrams && ../../.venv/bin/python generate.py

Writes <name>.svg and <name>.png for each diagram.
"""

import base64
import os
from html import escape

import cairosvg
import diagrams
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

RESOURCES = os.path.join(os.path.dirname(os.path.dirname(diagrams.__file__)), "resources")
FONT = "DejaVu Sans, Helvetica, Arial, sans-serif"

# Grid: column and row units in pixels (the drawing is shifted to fit).
COL, ROW = 175, 125
ICON = 60

# Group styles (AWS architecture icon guide colours).
STYLES = {
    "aws": dict(fill="#FFFFFF", stroke="#232F3E", width=2, dash=None),
    "vpc": dict(fill="#F7FBF2", stroke="#7AA116", width=2, dash=None),
    "public": dict(fill="#E9F3E6", stroke="#7AA116", width=1.5, dash=None),
    "private": dict(fill="#E6F2F8", stroke="#00A4A6", width=1.5, dash=None),
    "host": dict(fill="#FFFFFF", stroke="#ED7100", width=1.5, dash="6,4"),
    "github": dict(fill="#F6F8FA", stroke="#6E7781", width=1.5, dash="6,4"),
}

# One colour per step number; grey for plain connectors.
STEP_COLOURS = ["#D13212", "#1F6FEB", "#1A7F37", "#8250DF", "#BF8700",
                "#E36209", "#0E8A8A", "#C2185B"]
GREY = "#8C959F"


def icon_uri(cls):
    path = os.path.join(RESOURCES, cls._icon_dir.replace("resources/", ""), cls._icon)
    with open(path, "rb") as f:
        return "data:image/png;base64," + base64.b64encode(f.read()).decode()


class Drawing:
    def __init__(self, name, title):
        self.name, self.title = name, title
        self.nodes, self.groups, self.edges = {}, [], []

    # --- building --------------------------------------------------------------
    def node(self, key, cls, label, col, row):
        x, y = col * COL, row * ROW
        lines = label.split("\n")
        width = max(ICON, max(len(l) for l in lines) * 7.4)
        self.nodes[key] = dict(cls=cls, lines=lines, x=x, y=y, w=width,
                               top=y - ICON / 2, bottom=y + ICON / 2 + 8 + 15 * len(lines))

    def group(self, title, style, members, pad=18, left=0, top=0, title_at="top", align="left"):
        """A box around members (node keys or earlier groups). left/top: extra
        space on that side. title_at: "top" or "bottom"; align: "left"/"right"."""
        boxes = []
        for m in members:
            if isinstance(m, dict):
                boxes.append((m["x1"], m["y1"], m["x2"], m["y2"]))
            else:
                n = self.nodes[m]
                boxes.append((n["x"] - n["w"] / 2, n["top"], n["x"] + n["w"] / 2, n["bottom"]))
        band = 24
        x1 = min(b[0] for b in boxes) - pad - left
        x2 = max(b[2] for b in boxes) + pad
        y1 = min(b[1] for b in boxes) - pad - top - (band if title_at == "top" else 0)
        y2 = max(b[3] for b in boxes) + pad + (band if title_at == "bottom" else 0)
        title_w = len(title) * 8.7 + 24
        if x2 - x1 < title_w:  # the title always fits inside its box
            if align == "right":
                x1 = x2 - title_w
            else:
                x2 = x1 + title_w
        g = dict(title=title, style=style, x1=x1, y1=y1, x2=x2, y2=y2, title_at=title_at, align=align)
        self.groups.append(g)
        return g

    def anchor(self, key, side, dx=0):
        """N: above the icon. S: below the name. E/W: beside the icon."""
        n = self.nodes[key]
        half = ICON / 2 + 6
        return {"N": (n["x"] + dx, n["top"] - 6), "S": (n["x"] + dx, n["bottom"] + 4),
                "E": (n["x"] + half, n["y"] + dx),
                "W": (n["x"] - half, n["y"] + dx)}[side]

    def point(self, spec):
        if spec[0] in self.nodes:
            return self.anchor(*spec)
        return (spec[0] * COL, spec[1] * ROW)

    def edge(self, start, end, via=(), step=None, text="", dashed=False, label_at=None, arrow=True):
        """start/end: (node key, side[, offset]) or a grid point (col, row).
        via: ("x", col) / ("y", row) turns at that column / row, or (col, row)."""
        points = [self.point(start)]
        for v in via:
            if v[0] == "x":
                points.append((v[1] * COL, points[-1][1]))
            elif v[0] == "y":
                points.append((points[-1][0], v[1] * ROW))
            else:
                points.append((v[0] * COL, v[1] * ROW))
        end_point = self.point(end)
        last = points[-1]
        if last[0] != end_point[0] and last[1] != end_point[1]:  # one right-angle turn
            vertical_end = isinstance(end[1], str) and end[1] in "NS"
            points.append((end_point[0], last[1]) if vertical_end else (last[0], end_point[1]))
        points.append(end_point)
        self.edges.append(dict(points=points, step=step, text=text, dashed=dashed,
                               label_at=label_at, arrow=arrow))

    # --- rendering ---------------------------------------------------------------
    def render(self):
        labels = []
        for e in self.edges:
            idx = len(STEP_COLOURS) if e["step"] is None else (e["step"] - 1) % len(STEP_COLOURS)
            e["idx"], e["colour"] = idx, (GREY if e["step"] is None else STEP_COLOURS[idx])
            if e["step"] is not None or e["text"]:
                text = (f"{e['step']}. " if e["step"] is not None else "") + e["text"]
                if e["label_at"]:
                    lx, ly = e["label_at"][0] * COL, e["label_at"][1] * ROW
                else:  # middle of the longest segment
                    segs = list(zip(e["points"], e["points"][1:]))
                    (ax, ay), (bx, by) = max(segs, key=lambda s: abs(s[0][0] - s[1][0]) + abs(s[0][1] - s[1][1]))
                    lx, ly = (ax + bx) / 2, (ay + by) / 2
                labels.append((lx, ly, text, e["colour"], len(text) * 7.6 + 14))

        # Bounding box of everything, then shift it below the title.
        xs, ys = [], []
        for g in self.groups:
            xs += [g["x1"], g["x2"]]; ys += [g["y1"], g["y2"]]
        for n in self.nodes.values():
            xs += [n["x"] - n["w"] / 2, n["x"] + n["w"] / 2]; ys += [n["top"], n["bottom"]]
        for e in self.edges:
            xs += [p[0] for p in e["points"]]; ys += [p[1] for p in e["points"]]
        for lx, ly, _, _, w in labels:
            xs += [lx - w / 2, lx + w / 2]; ys += [ly - 11, ly + 11]
        margin, title_band = 30, 80
        dx, dy = margin - min(xs), title_band - min(ys)
        width, height = max(xs) + dx + margin, max(ys) + dy + margin
        width = max(width, len(self.title) * 15 + 2 * margin)

        out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width:.0f}" height="{height:.0f}" '
               f'viewBox="0 0 {width:.0f} {height:.0f}" font-family="{FONT}">', '<defs>']
        for i, colour in enumerate(STEP_COLOURS + [GREY]):
            out.append(f'<marker id="a{i}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" '
                       f'markerHeight="7" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="{colour}"/></marker>')
        out.append('</defs>')
        out.append('<rect width="100%" height="100%" fill="#FFFFFF"/>')
        out.append(f'<text x="{width / 2:.0f}" y="46" text-anchor="middle" font-size="24" '
                   f'font-weight="bold" fill="#24292F">{escape(self.title)}</text>')
        out.append(f'<g transform="translate({dx:.0f},{dy:.0f})">')

        for g in sorted(self.groups, key=lambda g: (g["x2"] - g["x1"]) * (g["y2"] - g["y1"]), reverse=True):
            s = STYLES[g["style"]]
            dash = f' stroke-dasharray="{s["dash"]}"' if s["dash"] else ""
            out.append(f'<rect x="{g["x1"]:.0f}" y="{g["y1"]:.0f}" width="{g["x2"] - g["x1"]:.0f}" '
                       f'height="{g["y2"] - g["y1"]:.0f}" rx="10" fill="{s["fill"]}" stroke="{s["stroke"]}" '
                       f'stroke-width="{s["width"]}"{dash}/>')
            ty = g["y1"] + 19 if g["title_at"] == "top" else g["y2"] - 9
            if g["align"] == "left":
                tx, anchor = g["x1"] + 12, "start"
            else:
                tx, anchor = g["x2"] - 12, "end"
            out.append(f'<text x="{tx:.0f}" y="{ty:.0f}" text-anchor="{anchor}" font-size="14" '
                       f'font-weight="bold" fill="{s["stroke"]}">{escape(g["title"])}</text>')

        for e in self.edges:
            width_px = 1.6 if e["step"] is None else 2.4
            dash = ' stroke-dasharray="7,5"' if e["dashed"] else ""
            marker = f' marker-end="url(#a{e["idx"]})"' if e["arrow"] else ""
            d = " ".join(f"{'M' if i == 0 else 'L'}{x:.0f},{y:.0f}" for i, (x, y) in enumerate(e["points"]))
            out.append(f'<path d="{d}" fill="none" stroke="{e["colour"]}" stroke-width="{width_px}"{dash} '
                       f'stroke-linejoin="round"{marker}/>')
        for lx, ly, text, colour, w in labels:  # on top of every line
            out.append(f'<rect x="{lx - w / 2:.0f}" y="{ly - 11:.0f}" width="{w:.0f}" height="22" rx="11" '
                       f'fill="#FFFFFF" stroke="{colour}" stroke-width="1.2"/>')
            out.append(f'<text x="{lx:.0f}" y="{ly + 4.5:.0f}" text-anchor="middle" font-size="12.5" '
                       f'font-weight="bold" fill="{colour}">{escape(text)}</text>')

        for n in self.nodes.values():
            out.append(f'<image x="{n["x"] - ICON / 2:.0f}" y="{n["top"]:.0f}" width="{ICON}" height="{ICON}" '
                       f'href="{icon_uri(n["cls"])}"/>')
            for i, line in enumerate(n["lines"]):
                out.append(f'<text x="{n["x"]:.0f}" y="{n["y"] + ICON / 2 + 20 + 15 * i:.0f}" text-anchor="middle" '
                           f'font-size="12.5" fill="#24292F">{escape(line)}</text>')
        out.append("</g></svg>")
        svg = "\n".join(out)
        with open(f"{self.name}.svg", "w") as f:
            f.write(svg)
        cairosvg.svg2png(bytestring=svg.encode(), write_to=f"{self.name}.png", scale=1.5)


# 1. Overview ---------------------------------------------------------------------
# Secrets and S3 are reached upwards and metrics/logs run along one line at the
# bottom, so no two flows cross.
d = Drawing("overview", "BMC on AWS: dev environment")
SVC = 5.2                      # column of the services; three arrows leave its top
d.node("users", Users, "Users", 0, 1)
d.node("internet", InternetAlt1, "Internet\n(GHCR, updates)", 0, -2.6)
d.node("igw", InternetGateway, "Internet gateway", 1.2, 1)
d.node("edge", EC2Instance, "Edge host\nNAT + port forward", 2.5, 1)
d.node("edge_alloy", Grafana, "Alloy agent", 2.5, 2.3)
d.node("traefik", Traefik, "Traefik", 4.0, 1)
d.node("services", Docker, "Services\n(containers)", SVC, 1)
d.node("app_alloy", Grafana, "Alloy agent", 4.0, 2.3)
d.node("mysql", Mysql, "MySQL 8.4", 6.6, 1)
d.node("ebs", ElasticBlockStoreEBSVolume, "Data volume\n(EBS)", 7.8, 1)
d.node("db_alloy", Grafana, "Alloy agent", 7.8, 2.3)
d.node("prom", Prometheus, "Prometheus :9090", 9.8, 2.0)
d.node("loki", Loki, "Loki :3100", 9.8, 3.4)
d.node("grafana", Grafana, "Grafana", 11.0, 2.7)
d.node("endpoint", Endpoint, "S3 gateway\nendpoint", 6.6, -0.9)
d.node("params", SystemsManagerParameterStore, "Parameter Store\n(secrets)", SVC + 4 / COL, -2.6)
d.node("attachments", SimpleStorageServiceS3Bucket, "S3 attachments\n(uploaded files)", 6.2, -2.6)
d.node("backups", SimpleStorageServiceS3Bucket, "S3 backups\n(MySQL dumps)", 7.1, -2.6)
public = d.group("Public subnet · 10.10.0.0/24", "public", ["edge", "edge_alloy"], title_at="bottom")
app = d.group("App host · 10.10.1.10", "host", ["traefik", "services", "app_alloy"])
db = d.group("Database host · 10.10.1.30", "host", ["mysql", "ebs", "db_alloy"], align="right")
mon = d.group("Monitoring host · 10.10.1.20", "host", ["prom", "loki", "grafana"])
private = d.group("Private subnet · 10.10.1.0/24", "private", [app, db, mon], top=34)
vpc = d.group("VPC bmc-dev · 10.10.0.0/16 · eu-north-1a", "vpc",
              ["igw", public, private, "endpoint"], title_at="bottom")
regional = d.group("Regional services", "aws", ["params", "attachments", "backups"], pad=16)
d.group("AWS account · eu-north-1", "aws", [vpc, regional], pad=22, title_at="bottom")
# Request path
d.edge(("users", "E"), ("igw", "W"), step=1, text="HTTP 80/443")
d.edge(("igw", "E"), ("edge", "W"))
d.edge(("edge", "E"), ("traefik", "W"), step=2, text="forward")
d.edge(("traefik", "E"), ("services", "W"))
d.edge(("services", "E"), ("mysql", "W"), step=3, text="SQL 3306")
d.edge(("mysql", "E"), ("ebs", "W"))
# Upwards: internet through NAT, secrets, S3 through the endpoint
d.edge(("services", "N", -20), ("edge", "N"), via=[("y", 0.27)], step=4, text="outbound via NAT", dashed=True)
d.edge(("igw", "N"), ("internet", "E"), via=[("y", -2.6)], dashed=True, text="to internet")
d.edge(("services", "N", 4), ("params", "S"), step=7, text="read secrets", dashed=True, label_at=(SVC - 0.15, -1.55))
d.edge(("services", "N", 22), ("endpoint", "W"), via=[("y", -0.9)], step=5, text="attachments", dashed=True, label_at=(5.95, -0.9))
d.edge(("mysql", "N"), ("endpoint", "S"), step=6, text="backups", dashed=True)
d.edge(("endpoint", "N", -6), ("attachments", "S"), via=[("y", -1.75), ("x", 6.2)])
d.edge(("endpoint", "N", 6), ("backups", "S"), via=[("y", -1.75), ("x", 7.1)])
# Downwards: every Alloy agent joins one line to the monitoring host
BUS = 3.4
d.edge(("edge_alloy", "W"), (8.9, BUS), via=[("x", 1.9), ("y", BUS)], arrow=False)
d.edge(("app_alloy", "S"), (4.0, BUS), arrow=False)
d.edge(("db_alloy", "S"), (7.8, BUS), arrow=False)
d.edge((8.9, BUS), ("prom", "W"), via=[("y", 2.0)], step=8, text="metrics", label_at=(8.9, 2.7))
d.edge((8.9, BUS), ("loki", "W"), step=8, text="logs", label_at=(9.25, BUS))
d.edge(("prom", "E"), ("grafana", "W"), via=[("x", 10.4)])
d.edge(("loki", "E"), ("grafana", "W"), via=[("x", 10.4)])
d.render()


# 2. Infrastructure pipeline ---------------------------------------------------------
d = Drawing("infra-pipeline", "Infrastructure changes: merge → plan → approve → apply")
d.node("dev", User, "Developer", 0, 1)
d.node("repo", Github, "main branch", 1.3, 1)
d.node("ci", GithubActions, "CI workflow\nlint · plan · apply", 2.6, 1)
d.node("tf", Terraform, "Terraform", 3.9, 1)
d.node("approver", User, "Maintainer\n(approver)", 2.6, 2.8)
d.node("key", IdentityAndAccessManagementIamLongTermSecurityCredential, "bmc-ci\naccess key", 3.9, 2.8)
d.node("state", SimpleStorageServiceS3Bucket, "Terraform state\n(S3)", 5.4, 1)
d.node("resources", EC2Instance, "Network, hosts,\nIAM, buckets", 6.8, 1)
d.node("sts", IdentityAndAccessManagementIamAWSSts, "STS\nAssumeRole", 5.4, 2.8)
d.node("role", IdentityAndAccessManagementIamRole, "bmc-admin role\n(permissions boundary)", 6.8, 2.8)
d.group("GitHub · labdsof-infra", "github", ["repo", "ci", "tf", "key"])
env = d.group("dev / prod", "vpc", ["resources"], pad=12)
d.group("AWS account · eu-north-1", "aws", ["state", "sts", "role", env])
d.edge(("dev", "E"), ("repo", "W"), step=1, text="merge PR")
d.edge(("repo", "E"), ("ci", "W"), step=2, text="run")
d.edge(("ci", "E"), ("tf", "W"), step=3, text="plan")
d.edge(("tf", "E"), ("state", "W"), text="read state")
d.edge(("approver", "N"), ("ci", "S"), step=4, text="approve")
d.edge(("tf", "S"), ("key", "N"), text="uses")
d.edge(("key", "E"), ("sts", "W"), step=5, text="assume role")
d.edge(("sts", "E"), ("role", "W"))
d.edge(("role", "N"), ("resources", "S"), step=6, text="apply")
d.render()


# 3. Application deploy ---------------------------------------------------------------
d = Drawing("app-deploy", "Application deploy to dev")
d.node("dev", User, "Developer", 0, 1)
d.node("repo", Github, "main branch", 1.2, 1)
d.node("ci", GithubActions, "dev.yml +\ndeploy.yml", 2.4, 1)
d.node("ghcr", Docker, "GHCR\nlabdsof-<service>", 4.0, 1)
d.node("zap", GithubActions, "ZAP scan", 2.4, -0.6)
d.node("key", IdentityAndAccessManagementIamLongTermSecurityCredential, "bmc-deploy-dev\naccess key", 2.4, 2.7)
d.node("run", SystemsManagerRunCommand, "SSM Run Command", 5.1, 2.7)
d.node("edge", EC2Instance, "Edge host", 6.8, 1)
d.node("deploy", EC2Instance, "bmc-app-deploy", 6.8, 2.7)
d.node("traefik", Traefik, "Traefik +\nservices", 8.1, 2.7)
d.node("params", SystemsManagerParameterStore, "Parameter Store\n(DB passwords)", 6.8, 4.8)
d.group("GitHub · LABDSOF_G9A", "github", ["repo", "ci", "ghcr", "zap", "key"])
public = d.group("Public subnet", "public", ["edge"], left=110)
apphost = d.group("App host", "host", ["deploy", "traefik"], left=40)
private = d.group("Private subnet", "private", [apphost], left=50)
vpc = d.group("VPC bmc-dev", "vpc", [public, private])
d.group("AWS account · eu-north-1", "aws", [vpc, "run", "params"])
d.edge(("dev", "E"), ("repo", "W"), step=1, text="merge PR")
d.edge(("repo", "E"), ("ci", "W"))
d.edge(("ci", "E"), ("ghcr", "W"), step=2, text="build · sign · push")
d.edge(("ci", "S"), ("key", "N"))
d.edge(("key", "E"), ("run", "W"), step=3, text="send command")
d.edge(("run", "E"), ("deploy", "W"), step=4, text="deploy <tag>")
d.edge(("deploy", "S"), ("params", "N"), step=5, text="read passwords", label_at=(6.8, 4.25))
d.edge(("deploy", "N"), ("edge", "S"), dashed=True)
d.edge(("edge", "W"), ("ghcr", "E"), step=6, text="pull images (via NAT)", dashed=True)
d.edge(("deploy", "E"), ("traefik", "W"), text="up -d")
d.edge(("ci", "N"), ("zap", "S"))
d.edge(("zap", "E"), ("edge", "N"), via=[("x", 6.8)], step=7, text="DAST scan")
d.edge(("edge", "E"), ("traefik", "N"), via=[("x", 8.1)], text="HTTP")
d.render()


# 4. Metrics and logs ---------------------------------------------------------------------
# On every host an Alloy agent collects what runs there; all agents join one
# line that splits into metrics (Prometheus) and logs (Loki).
d = Drawing("observability", "Metrics and logs: Alloy on every host → monitoring host")
BUS = 1.0
d.node("edge_src", EC2Instance, "System\n(CPU, memory, disk,\njournal)", -1.2, -0.4)
d.node("edge_alloy", Grafana, "Alloy agent", 0, -0.4)
d.node("app_src", Docker, "Containers\n(+ system)", -1.2, 1.7)
d.node("app_alloy", Grafana, "Alloy agent", 0, 1.7)
d.node("db_src", Mysql, "MySQL\n(+ containers, system)", -1.2, 3.3)
d.node("db_alloy", Grafana, "Alloy agent", 0, 3.3)
d.node("prom", Prometheus, "Prometheus :9090\n(metrics, 7 days)", 2.3, 2.5)
d.node("loki", Loki, "Loki :3100\n(logs, 7 days)", 2.3, 4.1)
d.node("mon_alloy", Grafana, "Alloy agent\n(this host)", 2.3, 5.35)
d.node("grafana", Grafana, "Grafana\n127.0.0.1:3000", 3.7, 3.3)
d.node("ssm", SystemsManager, "Session Manager\nport forwarding", 5.2, 3.3)
d.node("admin", User, "Admin\n(browser on\nlocalhost:3000)", 6.6, 3.3)
edge_host = d.group("Edge host", "host", ["edge_src", "edge_alloy"])
public = d.group("Public subnet", "public", [edge_host])
app_host = d.group("App host · 10.10.1.10", "host", ["app_src", "app_alloy"])
db_host = d.group("Database host · 10.10.1.30", "host", ["db_src", "db_alloy"])
mon_host = d.group("Monitoring host · 10.10.1.20", "host", ["prom", "loki", "mon_alloy", "grafana"])
private = d.group("Private subnet", "private", [app_host, db_host, mon_host])
vpc = d.group("VPC bmc-dev", "vpc", [public, private])
d.group("AWS account · eu-north-1", "aws", [vpc, "ssm"])
# What each agent reads
d.edge(("edge_src", "E"), ("edge_alloy", "W"))
d.edge(("app_src", "E"), ("app_alloy", "W"))
d.edge(("db_src", "E"), ("db_alloy", "W"))
# One line joins every agent ...
d.edge(("edge_alloy", "E"), (BUS, 5.35), via=[("x", BUS)], arrow=False)
d.edge(("app_alloy", "E"), (BUS, 1.7), arrow=False)
d.edge(("db_alloy", "E"), (BUS, 3.3), arrow=False)
d.edge(("mon_alloy", "W"), (BUS, 5.35), arrow=False)
# ... and splits into metrics and logs
d.edge((BUS, 2.5), ("prom", "W"), step=1, text="metrics", label_at=(1.55, 2.5))
d.edge((BUS, 4.1), ("loki", "W"), step=2, text="logs", label_at=(1.55, 4.1))
d.edge(("prom", "E"), ("grafana", "W"), via=[("x", 3.0)], step=3, text="query", label_at=(3.0, 2.85))
d.edge(("loki", "E"), ("grafana", "W"), via=[("x", 3.0)])
d.edge(("admin", "W"), ("ssm", "E"), step=4, text="open Grafana")
d.edge(("ssm", "W"), ("grafana", "E"), text="port forward")
d.render()


# 5. Administration ------------------------------------------------------------------------
d = Drawing("admin-access", "Administration: no SSH port, no stored keys")
d.node("admin", User, "Admin", 0, 1.6)
d.node("ansible", Ansible, "Ansible\nsite.yml", 0, 3.4)
d.node("connect", IdentityAndAccessManagementIamTemporarySecurityCredential,
       "EC2 Instance Connect\n(60 s SSH key)", 1.7, 5.0)
d.node("ssm", SystemsManager, "Session Manager", 2.7, 1.6)
d.node("edge", EC2Instance, "Edge host", 4.6, 0.3)
d.node("app", EC2Instance, "App host", 4.6, 2.0)
d.node("db", EC2Instance, "Database host", 4.6, 3.3)
d.node("mon", EC2Instance, "Monitoring host", 4.6, 4.6)
public = d.group("Public subnet", "public", ["edge"])
private = d.group("Private subnet", "private", ["app", "db", "mon"])
vpc = d.group("VPC bmc-dev", "vpc", [public, private])
d.group("AWS account · eu-north-1", "aws", ["ssm", "connect", vpc], title_at="bottom")
d.edge(("admin", "E"), ("ssm", "W"), step=1, text="shell")
d.edge(("admin", "S"), ("ansible", "N"), step=2, text="configure")
d.edge(("ansible", "S"), ("connect", "W"), via=[("y", 5.0)], step=3, text="push key", label_at=(0.85, 5.0))
d.edge(("ansible", "E"), ("ssm", "S"), via=[("x", 2.7)], step=4, text="SSH inside SSM session",
       label_at=(1.35, 3.4))
for host, row in (("edge", 0.3), ("app", 2.0), ("db", 3.3), ("mon", 4.6)):
    d.edge(("ssm", "E"), (host, "W"), via=[("x", 3.6), ("y", row)])
d.render()


# 6. Database image ----------------------------------------------------------------------------
d = Drawing("database-image", "Database image and host")
d.node("admin", User, "Admin\n(packer build)", 2.4, -1.4)
d.node("ansible", Ansible, "Ansible\ndatabase-image.yml", 0, 1)
d.node("ssm", SystemsManager, "Session Manager", 1.2, 1)
d.node("builder", EC2Instance, "Temporary\nbuild host", 2.4, 1)
d.node("ami", EC2Ami, "AMI\nbmc-database-<version>", 3.8, 2.8)
d.node("tf", Terraform, "Terraform", 5.2, -1.4)
d.node("db", EC2Instance, "Database host", 5.2, 1)
d.node("ebs", ElasticBlockStoreEBSVolume, "Data volume\n(EBS)", 6.4, 1)
d.node("params", SystemsManagerParameterStore, "Parameter Store\n(DB passwords)", 5.2, 2.8)
dbhost = d.group("Database host · 10.10.1.30", "host", ["db", "ebs"], align="right", title_at="bottom")
private = d.group("VPC bmc-dev · private subnet", "private", ["builder", dbhost], align="right")
d.group("AWS account · eu-north-1", "aws", ["ssm", private, "ami", "params"])
d.edge(("admin", "S"), ("builder", "N"), step=1, text="start build", label_at=(2.4, -0.45))
d.edge(("ansible", "E"), ("ssm", "W"), step=2, text="configure")
d.edge(("ssm", "E"), ("builder", "W"))
d.edge(("builder", "S"), ("ami", "W"), via=[("y", 2.8)], step=3, text="save image", label_at=(3.0, 2.8))
d.edge(("ami", "N"), ("db", "W"), via=[("y", 1)])
d.edge(("tf", "S"), ("db", "N"), step=4, text="launch", label_at=(5.2, -0.45))
d.edge(("db", "E"), ("ebs", "W"))
d.edge(("db", "S"), ("params", "N"), step=5, text="read passwords at boot", label_at=(5.2, 2.2))
d.render()
