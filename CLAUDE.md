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

- **Apply**: push to `main` touching `terraform/**`, `governance/**`, `resources/**`, or `.github/workflows/apply.yml`, or manually via Actions → Terraform Apply → Run workflow
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

Bronze is browse-only for account users — `SELECT` is withheld to enforce pipeline-only ingestion at the raw layer. Silver and gold carry ABAC column masking (see below).

### Admin catalog

`admin` is a managed catalog (no ADLS container) that holds shared governance infrastructure. The `admin.shared` schema contains the masking UDFs referenced by ABAC policies. All team SPs get `ALL PRIVILEGES + MANAGE` on `admin` so they can deploy and execute functions during the governance setup job.

### ABAC column masking

Silver and gold catalogs carry Unity Catalog column mask policies. Policies are created by the `create_policies` DABs task and call UDFs defined in `admin.shared` (`governance/create_udfs.sql`).

**8 masking UDFs** in `admin.shared`:

| UDF | Input | Masking approach |
|---|---|---|
| `mask_email` | STRING | Masks local part + domain label; preserves TLD (`******@******.co.uk`) |
| `mask_dob` | DATE | Decade of birth (`1985-07-23 → 1980-01-01`), consistent with age bracket |
| `mask_age` | VARIANT | INT columns: decade floor (`35→30`); STRING columns: bracket (`"30-39"`) |
| `mask_ip` | STRING | First two octets (`192.168.*.*`); `[REDACTED]` for non-IPv4 |
| `mask_credit_card` | STRING | Last 4 digits (`**** **** **** 1234`) |
| `mask_phone` | STRING | Country code only (`+44 *** *** ****`); handles `+44` and `0044` prefixes |
| `mask_location` | STRING | UK postcode outward code if detectable (`SW1A`); `[REDACTED]` otherwise |
| `mask_sensitive` | VARIANT | `[REDACTED]` — generic redaction for identifiers and special-category data |

**8 policies per catalog** (silver + gold) in `governance/create_policies.sql`:

| Policy | UDF | Tags covered |
|---|---|---|
| `mask_email_columns` | `mask_email` | email_address |
| `mask_dob_columns` | `mask_dob` | date_of_birth |
| `mask_age_columns` | `mask_age` | age |
| `mask_ip_columns` | `mask_ip` | ip_address |
| `mask_credit_card_columns` | `mask_credit_card` | credit_card |
| `mask_phone_columns` | `mask_phone` | phone_number |
| `mask_location_columns` | `mask_location` | location |
| `mask_unknown_sensitive_columns` | `mask_sensitive` | Any `class.*` tag not in the 7 explicit tags above (catch-all covering name, vin, ssn, nhs, ethnicity, etc.) |

All policies exempt `sg-dbplat-pii-readers`, `sg-dbplat-data-stewards`, and team SPs. SP IDs are substituted into `{{job.parameters.exempt_sps}}` at CI time before `databricks bundle deploy`.

**Key constraint**: only one policy may match a column per user — Databricks returns a hard error if two policies match the same column for the same user. Each `class.*` tag appears in exactly one policy's `MATCH COLUMNS` condition.

### Governed tag grants

`databricks_grants` does not support `governed_tag` as a securable type (provider limitation as of `~> 1.60`). Instead, `GRANT ASSIGN ON TAG` SQL statements are generated by CI from `terraform output team_sp_application_ids` and uploaded to the workspace as `governance/grant_governed_tags.sql` via `databricks bundle deploy`. The `grant_governed_tags` DABs task runs them after `create_policies`.

25 tags covered: the full GDPR + PCI DSS set (`class.name`, `class.email_address`, `class.phone_number`, `class.ip_address`, `class.location`, `class.date_of_birth`, `class.age`, `class.iban_code`, `class.credit_card`, `class.us_bank_number`, `class.vin`, `class.driver_license`, `class.us_driver_license`, `class.passport`, `class.us_passport`, `class.us_ssn`, `class.uk_nino`, `class.uk_nhs`, `class.de_id_card`, `class.de_svnr`, `class.de_tax_id`, `class.ethnicity`, `class.marital_status`, `class.sexual_orientation`, `class.criminal_background`).

Principals granted `ASSIGN`: all team SPs + `sg-dbplat-data-stewards`.

### DABs governance job

`resources/jobs/governance.yml` defines the `platform-governance-setup` job with three tasks:

```
create_udfs → create_policies → grant_governed_tags
```

All are SQL tasks running against a team SQL warehouse. The job is idempotent (`CREATE OR REPLACE`) and runs after every CI apply. It can also be triggered manually from the Databricks UI.

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

After 14 days Azure will prompt to upgrade to Premium. If costs appear unexpectedly, check whether a SQL warehouse is running; Terraform creates one per team and they have a 10-minute auto-stop by default.

### Key constraint: one metastore per region

Databricks allows one Unity Catalog metastore per region per account. If a metastore already exists in the target region and isn't in Terraform state, the apply will fail. Options: import it (`terraform import databricks_metastore.this <id>`) or delete it from the Databricks account UI first.
