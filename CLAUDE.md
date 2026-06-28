# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo does

Deploys a minimum-viable Databricks lakehouse on Azure via Terraform: one Trial-tier workspace, ADLS Gen2 storage, Unity Catalog metastore, and a landing zone backed by Unity Catalog external volumes. Auth throughout is OIDC — no stored secrets anywhere.

## Common commands

All Terraform commands run from the `terraform/` directory. Local runs use Azure CLI credentials (`az login`); CI uses OIDC automatically.

```powershell
# First-time setup (run once each, in order)
.\scripts\bootstrap.ps1                                          # creates tfstate backend
.\scripts\oidc-setup.ps1 -GitHubRepo "org/repo"                 # creates SP + federated credential

# Normal Terraform workflow
cd terraform
terraform init
terraform plan
terraform apply
terraform destroy
```

There are no lint or test commands — this is pure Terraform/PowerShell with no application code.

## Triggering CI

- **Apply**: push to `main` touching `terraform/**`, or manually via Actions → Terraform Apply → Run workflow
- **Plan**: open a PR targeting `main` — posts the plan as a PR comment
- **Destroy**: Actions → Terraform Destroy → Run workflow → type `destroy-simple`

## Architecture

### Terraform layout

| File | Responsibility |
|---|---|
| `providers.tf` | Two Databricks provider aliases: `databricks.accounts` (metastore/assignment) and `databricks.workspace` (all UC objects) |
| `main.tf` | Azure resources: resource group, ADLS storage account + containers, Access Connector, workspace, landing lifecycle policy, metastore, workspace permission assignments |
| `catalogs.tf` | All Unity Catalog objects: external locations, catalogs, schemas, volumes, grants |
| `groups.tf` | Entra security groups, Databricks account-level mirror groups, group memberships, workspace bindings |
| `service-principals.tf` | Service principals — data-driven via `var.service_principals`, each gets an Entra app registration, optional GitHub OIDC federated credential, and Databricks workspace registration |
| `demo-users.tf` | Demo users (Norma Redacta, Seymour Cleartext, Stewart Tagger) and their Entra group memberships |
| `variables.tf` | Input variables including `groups`, `service_principals`, `demo_users`, and `landing_sources` — all data-driven |
| `backend.tf` | Remote state in Azure Blob Storage — values here must match what `bootstrap.ps1` created |

### Two Databricks providers

The `accounts` provider talks to `accounts.azuredatabricks.net` and can only be used for account-level resources (`databricks_metastore`, `databricks_metastore_assignment`, `databricks_group`, `databricks_group_role`, `databricks_mws_permission_assignment`). Everything else uses the `workspace` provider. Mixing them up causes confusing auth errors.

Key provider-specific resources:
- **`databricks_mws_permission_assignment`** (accounts provider) — assigns a group to a workspace with `USER` or `ADMIN` permissions. This is the correct resource; `databricks_workspace_assignment` does not exist in the provider.
- **`databricks_group_role`** (accounts provider) — assigns a role such as `"account_admin"` to a group.
- **`databricks_group`** (accounts provider) — creates an account-level group. Set `display_name` to match the Entra group so AIM can sync members automatically.

### Groups and access governance

Four Entra security groups are managed in `groups.tf`. Each has a Databricks account-level mirror group with the same display name; AIM (Automatic Identity Management) syncs membership from Entra to Databricks.

| Entra group | Databricks privileges |
|---|---|
| `sg-dbplat-data-platform-admins` | `account_admin` role, metastore `owner`, workspace `ADMIN` |
| `sg-dbplat-data-stewards` | Workspace `USER` |
| `sg-dbplat-pii-readers` | Workspace `USER` |
| `sg-dbplat-standard-readers` | Workspace `USER` |

The `data-platform-admins` group is seeded with `var.owner` (the `OWNER` GitHub secret — kept secret to avoid committing a personal email to a public repo).

**AIM race condition**: When Terraform creates the Entra group, AIM can sync it to Databricks before Terraform creates the `databricks_group` resource, causing an "already exists" error. Fix: delete the Databricks group from the account console, then re-run `terraform apply` immediately before AIM re-syncs. Once Terraform owns the group in state this conflict does not recur.

### Landing zone pattern

Landing is a raw file drop zone, not a Delta catalog. Structure:

- ADLS container `landing` has a 30-day Azure lifecycle purge policy
- `local.layers` only includes `["bronze", "silver", "gold"]` — landing is handled separately
- Each data source gets its own external volume at `/Volumes/landing/raw/<source>/` with scoped `READ_VOLUME`/`WRITE_VOLUME` grants
- Defined via `var.landing_sources` (map of source name → list of principals) — adding a source requires only a tfvars change

### Bronze/silver/gold catalogs

Each layer in `local.layers` gets: an ADLS container, a Databricks external location, a catalog (with `storage_root` pointing at its container), and a `default` schema.

Catalog grants follow a data mesh principle — all account users can browse every layer:

| Catalog | Account users | Pipeline SP |
|---|---|---|
| `bronze` | `USE_CATALOG`, `USE_SCHEMA` | `ALL PRIVILEGES` |
| `silver` | `USE_CATALOG`, `USE_SCHEMA`, `SELECT` | `ALL PRIVILEGES` |
| `gold` | `USE_CATALOG`, `USE_SCHEMA`, `SELECT` | `ALL PRIVILEGES` |

Bronze is browse-only for account users — `SELECT` is withheld to enforce pipeline-only data ingestion at the raw layer.

### State file location

`dbplat-simple-tfstate-rg` / `dbplatsimplestate` / container `tfstate` / key `simple-databricks.tfstate`. This is outside the main resource group and is not managed by Terraform itself — it must be created by `bootstrap.ps1` before `terraform init`.

### OIDC setup

`oidc-setup.ps1` creates the app registration `dbplat-simple-github-actions` and assigns it:
- `Contributor` on the subscription
- `User Access Administrator` on the subscription (required for Terraform to create role assignments for the Databricks Access Connector managed identity)
- `Storage Blob Data Contributor` on the state storage account
- Federated credential for subject `repo:<org/repo>:environment:dev`

The SP must also be added as a Databricks account admin manually at `accounts.azuredatabricks.net`.

### Service principals

Service principals are data-driven via `var.service_principals` in `service-principals.tf`, following the same pattern as groups and users. Each entry in the map creates:
- An Entra app registration and service principal
- A GitHub OIDC federated credential (if `github_repo` is set)
- A Databricks workspace registration

```hcl
service_principals = {
  pipeline = {
    display_name       = "sp-tfl-pipeline"
    github_repo        = "org/repo"
    github_environment = "dev"
  }
}
```

Adding a new service principal requires only a tfvars change.

### Cross-repo secret sync (GitHub App)

After every `terraform apply`, the workflow pushes two outputs to `juliandicker/tfl-disruption-data-pipeline` as GitHub Actions secrets:

| Secret | Terraform output |
|---|---|
| `AZURE_CLIENT_ID` | `pipeline_sp_application_id` |
| `DATABRICKS_HOST` | `workspace_url` |

This uses a GitHub App (`dbplat-deployment-bot`) instead of a PAT — no expiry, scoped only to the target repo with `secrets:write`. Two secrets are required in the `dev` environment:
- `APP_ID` — numeric GitHub App ID
- `APP_PRIVATE_KEY` — app private key in **PKCS#8** format (`-----BEGIN PRIVATE KEY-----`). GitHub generates keys in PKCS#1; convert before storing: `openssl pkcs8 -topk8 -inform PEM -outform PEM -nocrypt -in original.pem | gh secret set APP_PRIVATE_KEY --env dev`

### Workspace SKU: Trial tier

The workspace uses `sku = "trial"` in `main.tf`. Trial gives Premium features (including Unity Catalog) with no DBU charges for 14 days per workspace. This suits the deploy-test-destroy cycle used here — each fresh `terraform apply` starts a new 14-day trial.

After 14 days Azure will prompt to upgrade to Premium. If costs appear unexpectedly, check whether a SQL warehouse or cluster is running in the workspace UI; Terraform does not create any compute resources, but Unity Catalog system operations can spin up background compute automatically.

### Key constraint: one metastore per region

Databricks allows one Unity Catalog metastore per region per account. If a metastore already exists in the target region and isn't in Terraform state, the apply will fail. Options: import it (`terraform import databricks_metastore.this <id>`) or delete it from the Databricks account UI first.
