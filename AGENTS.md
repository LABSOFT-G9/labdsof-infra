# labdsof-infra — agent instructions

Infrastructure for BMC (ISEP LABDSOF 26/27). The team's shared rules, workflow and backlog live in the application repository [LABSOFT-G9/LABDSOF_G9A](https://github.com/LABSOFT-G9/LABDSOF_G9A): read its `AGENTS.md` and the `labdsof-workflow` skill there. They apply here too.

## Non-negotiables

- Never commit secrets, keys, state files or `*.tfvars` with secrets. Secrets live in SSM Parameter Store or GitHub environment secrets.
- Changes reach AWS only through a reviewed PR and CI: merging to `main` applies dev, and prod after approval. Never run `terraform apply` or `destroy` locally, or build or deregister an AMI, without the owner's explicit go-ahead; show the plan first.
- Do not claim anything is deployed, applied or working without evidence (plan output, run link, AWS console or CLI output).
- Do not force-push shared branches or rewrite published history.
- Authors never approve their own changes.

## Conventions

- Branches and commits as in the application repository: `feature/US-17-01-…`, commits `<ID>: <imperative summary>`, PRs reference `LABSOFT-G9/LABDSOF_G9A#N` with `Refs`.
- Environment-specific values go only in `environments/<env>/terraform.tfvars`. Modules take variables and never name an environment.
- Pin everything: provider versions in `versions.tf` (lock files committed), container images by digest, GitHub Actions by commit SHA.
- Before a PR: `terraform fmt -recursive`, `terraform validate` in each environment, `packer fmt` and `packer validate`.
