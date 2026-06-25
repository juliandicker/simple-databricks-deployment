# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo does

Deploys a minimum-viable Databricks lakehouse on Azure via Terraform: one Premium workspace, ADLS Gen2 storage, Unity Catalog metastore, and a landing zone backed by Unity Catalog external volumes. Auth throughout is OIDC — no stored secrets anywhere.

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
| `main.tf` | Azure resources: resource group, ADLS storage account + containers, Access Connector, workspace, landing lifecycle policy |
| `catalogs.tf` | All Unity Catalog objects: external locations, catalogs, schemas, volumes, grants |
| `variables.tf` | Input variables including `landing_sources` for per-source volume config |
| `backend.tf` | Remote state in Azure Blob Storage — values here must match what `bootstrap.ps1` created |

### Two Databricks providers

The `accounts` provider talks to `accounts.azuredatabricks.net` and can only be used for account-level resources (`databricks_metastore`, `databricks_metastore_assignment`). Everything else uses the `workspace` provider. Mixing them up causes confusing auth errors.

### Landing zone pattern

Landing is a raw file drop zone, not a Delta catalog. Structure:

- ADLS container `landing` has a 30-day Azure lifecycle purge policy
- `local.layers` only includes `["bronze", "silver", "gold"]` — landing is handled separately
- Each data source gets its own external volume at `/Volumes/landing/raw/<source>/` with scoped `READ_VOLUME`/`WRITE_VOLUME` grants
- Defined via `var.landing_sources` (map of source name → list of principals) — adding a source requires only a tfvars change

### Bronze/silver/gold catalogs

Each layer in `local.layers` gets: an ADLS container, a Databricks external location, a catalog (with `storage_root` pointing at its container), a `default` schema, and `USE_CATALOG`/`USE_SCHEMA`/`SELECT` granted to `account users`.

### State file location

`dbplat-simple-tfstate-rg` / `dbplatsimplestate` / container `tfstate` / key `simple-databricks.tfstate`. This is outside the main resource group and is not managed by Terraform itself — it must be created by `bootstrap.ps1` before `terraform init`.

### OIDC setup

`oidc-setup.ps1` creates the app registration `dbplat-simple-github-actions` and assigns it:
- `Contributor` on the subscription
- `User Access Administrator` on the subscription (required for Terraform to create role assignments for the Databricks Access Connector managed identity)
- `Storage Blob Data Contributor` on the state storage account
- Federated credential for subject `repo:<org/repo>:environment:dev`

The SP must also be added as a Databricks account admin manually at `accounts.azuredatabricks.net`.

### Key constraint: one metastore per region

Databricks allows one Unity Catalog metastore per region per account. If a metastore already exists in the target region and isn't in Terraform state, the apply will fail. Options: import it (`terraform import databricks_metastore.this <id>`) or delete it from the Databricks account UI first.
