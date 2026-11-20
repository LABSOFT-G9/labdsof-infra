# Bootstrap state lives in the same bucket it creates, in the bootstrap/
# folder (admins only; the CI roles are denied access to it).
#
# The very first run cannot use it, because the bucket does not exist yet:
#   1. mv backend.tf backend.tf.off && terraform init && terraform apply
#   2. mv backend.tf.off backend.tf
#   3. terraform init -migrate-state -backend-config="bucket=<state_bucket output>"
# From then on: terraform init -backend-config="bucket=<state bucket>"
terraform {
  backend "s3" {
    key          = "bootstrap/terraform.tfstate"
    region       = "eu-north-1"
    encrypt      = true
    use_lockfile = true
  }
}
