# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo does

Deploys a minimum-viable Databricks lakehouse on Azure via Terraform: one Trial-tier workspace, ADLS Gen2 storage, Unity Catalog metastore, a landing zone backed by Unity Catalog external volumes, Unity Catalog catalogs/schemas/grants, groups, and data-mesh team service principals. Auth throughout is OIDC — no stored secrets anywhere.

This is the **infra** half of a two-repo split. The **governance** half — ABAC masking policies, audit tables, the SAR app, and the DABs jobs that maintain them — lives entirely in [`juliandicker/databricks-platform-governance`](https://github.com/juliandicker/databricks-platform-governance), which has no Terraform of its own. See "Governance repo" below for how the two connect. The split exists so a future, differently-architected infra project (e.g. VNet-injected) can reuse the same governance repo unchanged — everything Terraform-manageable stays here; everything DABs/SQL-only lives there.

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

There are no lint or test commands for the Terraform/PowerShell side. There is no application code in this repo — the SAR app and all DABs jobs live in `databricks-platform-governance`.

## Triggering CI

- **Apply**: push to `main` touching `terraform/**` or `.github/workflows/apply.yml`, or manually via Actions → Terraform Apply → Run workflow
- **Plan**: open a PR targeting `main` — posts the plan as a PR comment
- **Destroy**: Actions → Terraform Destroy → Run workflow → type `destroy-simple`

## Architecture

### Terraform layout

| File | Responsibility |
|---|---|
| `providers.tf` | Two Databricks provider aliases: `databricks.accounts` (metastore/assignment) and `databricks.workspace` (all UC objects) |
| `main.tf` | Azure resources: resource group, ADLS storage account + containers, Access Connector, workspace, landing lifecycle policy, metastore, workspace permission assignments |
| `catalogs.tf` | Unity Catalog objects: external locations, catalogs, default schemas, admin catalog (`admin.shared` UDF home), grants |
| `groups.tf` | Entra security groups, Databricks account-level mirror groups, group memberships, workspace bindings |
| `data-product-teams.tf` | Data mesh domain teams — each team gets an Entra SP, optional GitHub OIDC federated credential, Databricks workspace registration, schemas per data layer, landing volumes, and a SQL warehouse |
| `service-principals.tf` | Legacy platform service principals (data-driven via `var.service_principals`) — use `data-product-teams.tf` for domain team SPs instead |
| `demo-users.tf` | Demo users (Norma Redacta, Seymour Cleartext, Stewart Tagger) and their Entra group memberships |
| `variables.tf` | Input variables including `groups`, `data_product_teams`, `demo_users` — all data-driven |
| `outputs.tf` | Key outputs: workspace URL, team SP application IDs, team warehouse IDs |
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
| `sg-dbplat-data-stewards` | Workspace `USER` — exempt from ABAC masks; can see raw PII |
| `sg-dbplat-pii-readers` | Workspace `USER` — exempt from ABAC masks; can see raw PII |
| `sg-dbplat-standard-readers` | Workspace `USER` — sees masked output only |

The `data-platform-admins` group is seeded with `var.owner` (the `OWNER` GitHub secret — kept secret to avoid committing a personal email to a public repo).

**AIM race condition**: When Terraform creates the Entra group, AIM can sync it to Databricks before Terraform creates the `databricks_group` resource, causing an "already exists" error. Fix: delete the Databricks group from the account console, then re-run `terraform apply` immediately before AIM re-syncs. Once Terraform owns the group in state this conflict does not recur.

### Data product teams

Domain teams are data-driven via `var.data_product_teams` in `data-product-teams.tf`. Each entry in the map creates:
- An Entra app registration and service principal
- A GitHub OIDC federated credential (if `sp_github_repo` is set)
- A Databricks workspace registration
- Schemas in bronze, silver, and gold (one per `schemas` entry)
- Landing external volumes (one per `landing_sources` entry)
- A SQL warehouse (serverless 2X-Small by default, configurable)

```hcl
data_product_teams = {
  travel = {
    display_name          = "sp-travel-data-products"
    sp_github_repo        = "juliandicker/tfl-disruption-data-pipeline"
    sp_github_environment = "dev"
    landing_sources       = ["tfl"]
    schemas               = ["tfl"]
    warehouse = {}   # all defaults: serverless, 2X-Small, auto_stop 10 min
  }
}
```

Adding a new data product to a team, or adding a new domain team, requires only a tfvars change.

SQL warehouses are named `<team-key>-sql-warehouse` (e.g. `travel-sql-warehouse`). The `data_platform_admins` group gets `CAN_MANAGE`; the team SP gets `CAN_USE`.

### Landing zone pattern

Landing is a raw file drop zone, not a Delta catalog. Structure:

- ADLS container `landing` has a 30-day Azure lifecycle purge policy
- `local.layers` only includes `["bronze", "silver", "gold"]` — landing is handled separately
- Each team's sources get an external volume at `/Volumes/landing/raw/<source>/` with `READ_VOLUME`/`WRITE_VOLUME` scoped to the team SP
- Defined via `var.data_product_teams[*].landing_sources` — adding a source requires only a tfvars change

### Bronze/silver/gold catalogs

Each layer in `local.layers` gets: an ADLS container, a Databricks external location, a catalog (with `storage_root` pointing at its container), and a `default` schema. Team schemas (one per team × layer × schema name) are created by `data-product-teams.tf`.

Catalog grants follow a data mesh principle — all account users can browse every layer:

| Catalog | Account users | Team SP |
|---|---|---|
| `bronze` | `USE_CATALOG`, `USE_SCHEMA` | `ALL PRIVILEGES` on owned schemas only |
| `silver` | `USE_CATALOG`, `USE_SCHEMA` | `ALL PRIVILEGES` on owned schemas only |
| `gold` | `USE_CATALOG`, `USE_SCHEMA` | `ALL PRIVILEGES` on owned schemas only |

Bronze is browse-only for account users — `SELECT` is withheld to enforce pipeline-only ingestion at the raw layer. Silver and gold carry ABAC column masking — policy definitions and masking UDFs live in `databricks-platform-governance`, not here.

### Admin catalog

`admin` has its own ADLS container (`admin`) and external location, giving it explicit storage independent of the metastore root DAC. Schema shells (`admin.shared`, `admin.erasure`, `admin.access`, `admin.lineage_cache`) are created here by Terraform; contents are `databricks-platform-governance`'s concern. All team SPs get `ALL PRIVILEGES + MANAGE` on `admin`.

`sg-dbplat-data-product-sps` also includes `sp-data-platform` and — via a dynamic grant keyed on `var.sar_app_sp_id` — the SAR app's own SP. Update `var.sar_app_sp_id` here whenever the SAR app is recreated on a fresh workspace. This is now the *only* thing `var.sar_app_sp_id` is used for — the bronze/silver/gold and admin.* schema/catalog grants for the SAR app SP that used to also depend on it have moved to `databricks-platform-governance`'s `governance_setup` job (`governance/grant_sar_app_access.py`), which resolves the app's SP id itself via the Apps API instead of needing it handed over from here.

### system catalog

System schemas (`system.access` for audit logs/table/column lineage, plus `billing`/`compute`/etc.) are auto-managed by Databricks — confirmed via `databricks system-schemas list <metastore_id>`, which reports `state: MANAGED`. **Don't** declare any of them with a `databricks_system_schema` resource: doing so fails every time with "Provider produced inconsistent result after apply — Root object was present, but now absent", since the provider doesn't expect to manage the lifecycle of an already-auto-enabled schema. On a brand-new metastore they still take a short while to actually materialize, though — `databricks_grants.system_access` (granting `sp-data-platform` `USE_CATALOG`/`USE_SCHEMA`/`SELECT` on the whole `system` catalog, needed by `databricks-platform-governance`'s `lineage_cache_refresh` job to read `system.access.table_lineage`/`column_lineage`, and by the `access_audit` dashboard to read `system.access.audit`) hit "Schema 'system.access' does not exist" seconds after `databricks_metastore_assignment.this` completed on a fresh metastore. `time_sleep.wait_for_system_schemas` (60s) sits between them to buy that propagation window. The grant is catalog-scoped rather than `system.access`-scoped so future governance work against other system schemas doesn't need its own one-off grant added here.

### Governed tag grants

`sg-dbplat-governed-tags` (nests `sg-dbplat-data-product-sps` + `sg-dbplat-data-stewards`, both managed here) needs a manual account-level `ASSIGN` grant after each fresh deploy — see `databricks-platform-governance`'s docs for the procedure.

### Usage dashboard

The dashboard is created automatically by the CI `Create account usage dashboard (v2)` step using `AccountClient.usage_dashboards.create()` from the Databricks Python SDK (`dashboard_type=USAGE_DASHBOARD_TYPE_GLOBAL`, `major_version=USAGE_DASHBOARD_MAJOR_VERSION_2`). The API handles enabling the `system.billing` schema internally. The step is idempotent — if the dashboard already exists it skips silently. No manual import is needed.

`usage_dashboards.create()` has no `owner` parameter — a Lakeview dashboard's owner is fixed to whoever's credentials called the create API, and the dashboard permissions API only supports `CAN_READ`/`CAN_RUN`/`CAN_EDIT`/`CAN_MANAGE` (no `IS_OWNER`, so ownership can't be transferred afterward either). To make `sp-data-platform` the owner rather than the CI deploy SP that runs the rest of the apply, `apply.yml` re-authenticates as `sp-data-platform` (via a second `azure/login` + token exchange, right before this step) using a federated credential scoped to this repo (`azuread_application_federated_identity_credential.platform_sp_this_repo` in `data-product-teams.tf` — separate from the one scoped to the governance repo). `sp-data-platform` is already `account_admin` (via `sg-dbplat-data-platform-admins` membership), so it can call this account-level API directly.

### Governance repo

[`juliandicker/databricks-platform-governance`](https://github.com/juliandicker/databricks-platform-governance) is enabled from here exactly the way `tfl-disruption-data-pipeline` is (see "Cross-repo secret sync" below): this repo's Terraform creates `sp-data-platform` and gives it a federated credential scoped to that repo (`data_product_teams.data_platform_admins.sp_github_repo` in `terraform.tfvars`), and `apply.yml` pushes `AZURE_CLIENT_ID`/`DATABRICKS_HOST` into it as secrets after every apply. Nothing here triggers a deploy over there.

On a full fresh-workspace cycle, deploy in this order: `simple-databricks-deployment` (this repo) → `databricks-platform-governance` → `tfl-disruption-data-pipeline`. The data platform team owns `databricks-platform-governance`, and data-access-governance concerns that only make sense once the governance repo's own resources (chiefly the SAR app) exist — e.g. its schema/catalog UC grants — are that repo's responsibility, not something this repo's Terraform should reach across to configure. See `databricks-platform-governance`'s `governance/grant_sar_app_access.py` and this file's "Admin catalog" section above.

### State file location

`dbplat-simple-tfstate-rg` / `dbplatsimplestate` / container `tfstate` / key `simple-databricks.tfstate`. This is outside the main resource group and is not managed by Terraform itself — it must be created by `bootstrap.ps1` before `terraform init`.

### OIDC setup

`oidc-setup.ps1` creates the app registration `dbplat-simple-github-actions` and assigns it:
- `Contributor` on the subscription
- `User Access Administrator` on the subscription (required for Terraform to create role assignments for the Databricks Access Connector managed identity)
- `Storage Blob Data Contributor` on the state storage account
- Federated credential for subject `repo:<org/repo>:environment:dev`

The SP must also be added as a Databricks account admin manually at `accounts.azuredatabricks.net`.

### Cross-repo secret sync (GitHub App)

After every `terraform apply`, the workflow pushes outputs as GitHub Actions secrets to two other repos:

| Repo | Secret | Terraform output |
|---|---|---|
| `tfl-disruption-data-pipeline` | `AZURE_CLIENT_ID` | `pipeline_sp_application_id` |
| `tfl-disruption-data-pipeline` | `DATABRICKS_HOST` | `workspace_url` |
| `databricks-platform-governance` | `AZURE_CLIENT_ID` | `platform_sp_application_id` |
| `databricks-platform-governance` | `DATABRICKS_HOST` | `workspace_url` |

This uses a GitHub App (`dbplat-deployment-bot`) instead of a PAT — no expiry, scoped only to the target repos with `secrets:write`. Adding a new target repo requires **manually** adding it to the App's installation repo access (Settings → Applications → Installed GitHub Apps → Configure) — this isn't available via a regular user's `gh`/API token, only through the App's own installation management. Two secrets are required in this repo's `dev` environment:
- `APP_ID` — numeric GitHub App ID
- `APP_PRIVATE_KEY` — app private key in **PKCS#8** format (`-----BEGIN PRIVATE KEY-----`). GitHub generates keys in PKCS#1; convert before storing: `openssl pkcs8 -topk8 -inform PEM -outform PEM -nocrypt -in original.pem | gh secret set APP_PRIVATE_KEY --env dev`

`dbplat-deployment-bot` is scoped to `secrets:write` only, not `actions:write` — it can push secrets but can't trigger a `workflow_dispatch` on the target repos. Neither needs a fresh trigger from here; both resolve their own config independently at deploy time.

### Workspace SKU: Trial tier

The workspace uses `sku = "trial"` in `main.tf`. Trial gives Premium features (including Unity Catalog) with no DBU charges for 14 days per workspace. This suits the deploy-test-destroy cycle used here — each fresh `terraform apply` starts a new 14-day trial.

After 14 days Azure will prompt to upgrade to Premium. If costs appear unexpectedly, check whether a SQL warehouse is running; Terraform creates one per team and they have a 10-minute auto-stop by default.

### Key constraint: one metastore per region

Databricks allows one Unity Catalog metastore per region per account. If a metastore already exists in the target region and isn't in Terraform state, the apply will fail. Options: import it (`terraform import databricks_metastore.this <id>`) or delete it from the Databricks account UI first.
