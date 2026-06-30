# simple-databricks-deployment

Minimum viable Databricks lakehouse on Azure. One workspace, ADLS Gen2, Unity Catalog (landing raw-file zone + bronze/silver/gold Delta layers), deployed entirely via Terraform with OIDC auth and no stored secrets.

## Architecture

```
Azure Resource Group (dbplat-simple-rg)
├── ADLS Gen2 storage account
│   ├── container: metastore  (Unity Catalog system tables)
│   ├── container: landing    (30-day lifecycle purge on all blobs)
│   ├── container: bronze
│   ├── container: silver
│   ├── container: gold
│   └── container: admin      (platform governance tables — freshness_metrics etc.)
├── Databricks Access Connector (managed identity → Storage Blob Data Contributor)
└── Databricks Workspace (Trial SKU — Premium features, 14-day free trial)

Unity Catalog (account-level)
└── Metastore (owner: data-platform-admins) → assigned to workspace
    ├── Storage Credential (access connector managed identity)
    ├── External Location: landing / bronze / silver / gold / admin
    ├── Catalog: admin    → schema: shared → masking UDFs + platform metrics tables
    ├── Catalog: landing  → schema: raw → volume: <source>  (one per team source)
    ├── Catalog: bronze   → schema: default, <team schemas>
    ├── Catalog: silver   → schema: default, <team schemas>  + ABAC column masks
    └── Catalog: gold     → schema: default, <team schemas>  + ABAC column masks

Data product teams (one entry per domain in terraform.tfvars)
└── travel
    ├── Entra SP: sp-travel-data-products  (GitHub OIDC federated credential)
    ├── Landing volume: /Volumes/landing/raw/tfl/
    ├── Schemas: bronze.tfl, silver.tfl, gold.tfl
    └── SQL warehouse: travel-sql-warehouse (serverless 2X-Small)

Entra ID security groups (synced to Databricks account via AIM)
├── sg-dbplat-data-platform-admins  → Databricks: account admin, metastore owner, workspace ADMIN
├── sg-dbplat-data-stewards         → Databricks: workspace USER, ABAC exempt (sees raw PII)
├── sg-dbplat-pii-readers           → Databricks: workspace USER, ABAC exempt (sees raw PII)
├── sg-dbplat-standard-readers      → Databricks: workspace USER (sees masked data only)
├── sg-dbplat-data-product-sps      → holds all domain team SPs (nested inside governed-tags)
└── sg-dbplat-governed-tags         → single principal for ASSIGN on 18 governed tags
    ├── sg-dbplat-data-product-sps  (nested)
    └── sg-dbplat-data-stewards     (nested)
```

### Catalog access

Access follows a data mesh principle — all account users can browse every layer:

| Catalog | Account users | Team SP |
|---|---|---|
| `landing` | `USE_CATALOG`, `USE_SCHEMA` | `READ_VOLUME`, `WRITE_VOLUME` on owned volumes |
| `bronze` | `USE_CATALOG`, `USE_SCHEMA` | `ALL PRIVILEGES` on owned schemas |
| `silver` | `USE_CATALOG`, `USE_SCHEMA` | `ALL PRIVILEGES` on owned schemas |
| `gold` | `USE_CATALOG`, `USE_SCHEMA` | `ALL PRIVILEGES` on owned schemas |

Bronze is intentionally browse-only for account users — data access requires the team SP. Silver and gold are readable by all users but protected by ABAC column masking — standard readers see masked values; `pii-readers` and `data-stewards` see the raw data.

### ABAC column masking

Silver and gold carry Unity Catalog column mask policies driven by Databricks Data Classification (`class.*` governed tags). When Data Classification detects a PII or sensitive column, it applies a `class.*` tag; the matching policy then masks the value for standard readers.

**8 masking UDFs** in `admin.shared`:

| UDF | Example output |
|---|---|
| `mask_email` | `******@******.co.uk` |
| `mask_dob` | `1980-01-01` (decade of birth) |
| `mask_age` | `30` (INT) or `"30-39"` (STRING) |
| `mask_ip` | `192.168.*.*` |
| `mask_credit_card` | `**** **** **** 1234` |
| `mask_phone` | `+44 *** *** ****` |
| `mask_location` | `SW1A` (UK postcode outward code) or `[REDACTED]` |
| `mask_sensitive` | `[REDACTED]` |

9 policies per catalog cover all 25 GDPR + PCI DSS `class.*` tags explicitly. Databricks does not support namespace wildcards in policy conditions, so each tag is listed in exactly one policy. All policies are managed by the DABs governance job and are idempotent.

#### Governed tag ASSIGN permissions — manual step required

After each fresh deploy, `ASSIGN` must be granted once at account level to `sg-dbplat-governed-tags` — this covers all governed tags in one step. This cannot be automated — Databricks has not implemented governed tag permission management in the REST API or SDK. See **[docs/governed-tag-grants.md](docs/governed-tag-grants.md)** for the exact steps.

### Groups and access governance

Four Entra security groups govern access. Terraform creates them and manages membership; Databricks mirrors them via AIM (Automatic Identity Management):

| Entra group | Databricks role | Purpose |
|---|---|---|
| `sg-dbplat-data-platform-admins` | Account admin, metastore owner, workspace ADMIN | Platform operators |
| `sg-dbplat-data-stewards` | Workspace USER | Data quality and ownership — see unmasked data |
| `sg-dbplat-pii-readers` | Workspace USER | Access to raw PII-tagged columns |
| `sg-dbplat-standard-readers` | Workspace USER | Standard read access — masked data only |

The `data-platform-admins` group is seeded with the owner specified in the `OWNER` secret.

Two additional groups are managed by Terraform to minimise the governed tag ASSIGN grants:

- `sg-dbplat-data-product-sps` — holds all domain team SPs; new SPs are added automatically on each `terraform apply`
- `sg-dbplat-governed-tags` — nests `data-product-sps` and `data-stewards`; the single principal granted `ASSIGN` on all 18 governed tags

> **AIM and Terraform**: AIM can race against `terraform apply` when creating the Databricks mirror group for `data_platform_admins`. If an apply fails with "Group already exists", delete the Databricks group from the account console, then re-run the apply immediately before AIM re-syncs.

### Data product teams

Teams follow a data mesh model — each domain team owns one service principal and one or more data products (schemas + landing volumes). Adding a data product or a new team requires only a `terraform.tfvars` change:

```hcl
data_product_teams = {
  travel = {
    display_name          = "sp-travel-data-products"
    sp_github_repo        = "juliandicker/tfl-disruption-data-pipeline"
    sp_github_environment = "dev"
    landing_sources       = ["tfl"]   # /Volumes/landing/raw/tfl/
    schemas               = ["tfl"]   # bronze.tfl, silver.tfl, gold.tfl
  }
  # music = { ... }  # add a second domain team here — gets its own SP and isolation
}
```

Each team also gets a SQL warehouse named `<team>-sql-warehouse` (serverless 2X-Small, 10-min auto-stop by default), and an optional per-team cost centre override and budget alert:

```hcl
  travel = {
    display_name = "sp-travel-data-products"
    cost_centre  = "CC-210"   # overrides top-level cost_centre on budget policy tags
    budget = {
      enabled             = true
      alert_threshold_usd = 200
      alert_email         = "alerts@example.com"
    }
  }
```

### Serverless usage policies and cost governance

Every data product team gets a Databricks serverless usage policy (`databricks_budget_policy`) that automatically stamps all their serverless compute activity — notebooks, jobs, pipelines, model serving — with `team` and `cost_centre` tags. These flow into `system.billing.usage.custom_tags`, enabling per-team cost attribution and chargeback without any manual tagging by the team.

A separate platform policy covers serverless compute run directly by members of `sg-dbplat-data-platform-admins`.

Since each team SP is assigned to exactly one policy, Databricks auto-applies it to every new serverless resource that SP creates — no user action needed.

Optional monthly spend alerts (`databricks_budget`) can be enabled per team or at workspace level via tfvars (see Data product teams above). Alerts fire by email when list-price USD spend exceeds the configured threshold and are off by default.

> **CI prerequisite**: the `dbplat-simple-github-actions` SP must have the **Billing admin** role in the Databricks Account Console (User Management → Service principals → Roles) in addition to Account admin. Billing admin is required to create budget policies via API.

### Platform metadata column conventions

Every managed table in bronze, silver, and gold must carry three platform metadata columns. Teams are responsible for populating them in their pipelines:

| Column | Type | Set when | Purpose |
|---|---|---|---|
| `_inserted_at` | `TIMESTAMP` | First insert only — never updated | Immutable audit trail of when the row arrived in this layer |
| `_updated_at` | `TIMESTAMP` | Every write | Drives freshness SLA monitoring — staleness is measured against the table's configured SLA |
| `_delete_at` | `TIMESTAMP` | Set to the row's expiry date | Drives Auto TTL — the platform deletes rows after this date |

```python
# DLT example — all three columns populated by the pipeline
@dlt.table
def silver_journeys():
    return (
        dlt.read_stream("bronze_journeys")
        .withColumn("_inserted_at", current_timestamp())  # set once; use merge to preserve on updates
        .withColumn("_updated_at",  current_timestamp())
        .withColumn("_delete_at",   date_add(current_timestamp(), 365 * 7))  # 7-year retention
    )
```

Two governance jobs enforce these conventions:

**`platform-governance-setup`** — runs on every CI deploy. Creates/replaces masking UDFs and ABAC policies. DDL-only, no schedule needed.

**`platform-governance-daily`** — scheduled daily at 01:00 Europe/London, `pause_status: PAUSED` by default (suitable for demo environments — unpause in the Databricks UI when running live). Tasks:

- **`apply_auto_ttl`** — sweeps all managed tables that have `_delete_at` and applies `ALTER TABLE ... DELETE ROWS 0 DAYS AFTER _delete_at`. Idempotent.
- **`compute_freshness_metrics`** — queries `MAX(_updated_at)` per table and writes to `admin.shared.freshness_metrics`.
- **`create_retention_compliance_view`** — rebuilds `admin.shared.retention_compliance`, which surfaces structural compliance (`insertion_status`, `freshness_status`, `retention_status`) and operational SLA compliance (`sla_status`) for every managed table. Non-compliant and stale tables sort to the top.

```sql
SELECT * FROM admin.shared.retention_compliance WHERE sla_status = 'STALE';
```

#### Per-table freshness SLAs

Teams set the acceptable staleness window per table as a table property. The value is visible in the Unity Catalog Explorer under the table's **Details** tab.

```sql
-- Real-time pipeline — expect updates every hour
ALTER TABLE silver.tfl.journeys
SET TBLPROPERTIES ('platform.freshness_sla' = '1h');

-- Reference data — acceptable to update weekly
ALTER TABLE gold.reference.station_codes
SET TBLPROPERTIES ('platform.freshness_sla' = '7d');
```

| Unit | Example | Minutes |
|---|---|---|
| `m` | `30m` | 30 |
| `h` | `4h` | 240 |
| `d` | `7d` | 10,080 |
| `y` | `10y` | 5,259,600 |

Default if not set: `1d` (1,440 minutes). The `compute_freshness_metrics` job reads the property from each table and stores it in `admin.shared.freshness_metrics` alongside `max_updated_at`. The compliance view derives `sla_status`:

| Value | Meaning |
|---|---|
| `FRESH` | Last updated within the SLA window |
| `STALE` | Last updated outside the SLA window |
| `NEVER_UPDATED` | `_updated_at` column exists but all values are null |
| `NO_COLUMN` | `_updated_at` column is missing (structural non-compliance) |
| `ERROR` | Freshness metrics computation failed for this table |

### Platform Data Governance dashboard

`dashboards/platform_data_governance.lvdash.json` is an AI/BI dashboard deployed by the DABs bundle. It provides:

- **KPI row** — total tables monitored, fully compliant count, non-compliant count, overall compliance %
- **Compliance rate by catalog** — bar chart per bronze/silver/gold
- **Non-compliant tables by schema** — which teams have the most gaps
- **Non-compliant tables detail** — full list with per-column status
- **Stale tables page** — tables where `max_updated_at` is older than 24 hours or null

The warehouse is resolved automatically by name (`data_platform_admins-sql-warehouse`) — no hardcoded IDs.

### Landing zone

Landing is a raw file drop zone — CSV, JSON, Parquet, etc. Files are purged automatically after 30 days by an Azure lifecycle policy. No Delta tables are created here.

Each team source gets its own Unity Catalog external volume at `/Volumes/landing/raw/<source>/` with access locked to the team SP.

## Prerequisites

- Azure subscription with Contributor rights
- Databricks account (accounts.azuredatabricks.net) — account admin rights needed to create a metastore
- GitHub repository with Actions enabled
- Terraform ≥ 1.9 (for local runs)
- Azure CLI (for the bootstrap step only)

---

## Step 1 — Bootstrap the Terraform state backend

This is the one chicken-and-egg step: the remote backend storage must exist before `terraform init` can use it. Run the provided script once (requires the Azure CLI and an active `az login`):

```powershell
.\scripts\bootstrap.ps1
```

If you change the storage account name inside the script, update `storage_account_name` in `terraform/backend.tf` to match.

---

## Step 2 — Set up OIDC (Workload Identity Federation)

No client secrets are stored in GitHub. Instead, GitHub Actions exchanges a short-lived OIDC token for an Azure access token. Run the provided script, passing your GitHub repository as `org/repo`:

```powershell
.\scripts\oidc-setup.ps1 -GitHubRepo "YOUR_ORG/YOUR_REPO"
```

The script will print the values you need to add as GitHub secrets. It handles:
- Creating the app registration and service principal
- Assigning Contributor + User Access Administrator on the subscription (both needed — Terraform creates role assignments for Databricks managed identities)
- Assigning Storage Blob Data Contributor on the state storage account
- Adding the federated credential for the `dev` environment

> The service principal also needs to be a **Databricks account admin** to create and assign the Unity Catalog metastore. The script reminds you of this — add it at accounts.azuredatabricks.net → Settings → Identity and access → Service principals.

---

## Step 3 — Configure GitHub secrets and variables

In your GitHub repository go to **Settings → Secrets and variables → Actions**.

### Secrets (encrypted)

All values are stored as secrets — none are stored as plaintext variables.

| Name | Value |
|---|---|
| `AZURE_CLIENT_ID` | App registration client ID (`$APP_ID`) |
| `AZURE_TENANT_ID` | Azure tenant ID (`$TENANT_ID`) |
| `AZURE_SUBSCRIPTION_ID` | Azure subscription ID (`$SUBSCRIPTION_ID`) |
| `DATABRICKS_ACCOUNT_ID` | Your Databricks account ID (from accounts.azuredatabricks.net) |
| `OWNER` | Owner tag value — kept secret to avoid leaking personal email in a public repo |
| `DEMO_USER_PASSWORD` | Initial password for the three demo users (Norma Redacta, Seymour Cleartext, Stewart Tagger) |
| `APP_ID` | Numeric ID of the `dbplat-deployment-bot` GitHub App (used to push outputs to the pipeline repo) |
| `APP_PRIVATE_KEY` | Private key of the GitHub App in **PKCS#8** format — see note below |

These are set at the **environment** level (`dev`) to match the `environment: dev` declared in each workflow job.

> **GitHub App private key format**: GitHub generates App private keys in PKCS#1 format (`-----BEGIN RSA PRIVATE KEY-----`). GitHub Actions runners now use Node 24 which requires PKCS#8. Convert before storing:
> ```powershell
> & "C:\Program Files\Git\usr\bin\openssl.exe" pkcs8 -topk8 -inform PEM -outform PEM -nocrypt `
>   -in "path\to\downloaded-key.pem" | gh secret set APP_PRIVATE_KEY --env dev --repo YOUR_ORG/YOUR_REPO
> ```

---

## Step 3b — Create the GitHub App for cross-repo secret sync

The apply workflow automatically pushes `AZURE_CLIENT_ID` (team SP) and `DATABRICKS_HOST` (workspace URL) to any downstream pipeline repo after each apply. This uses a GitHub App rather than a PAT — no expiry and scoped only to the target repo.

1. Go to **github.com → profile → Settings → Developer settings → GitHub Apps → New GitHub App**
   - Set any homepage URL (e.g. your GitHub profile)
   - Uncheck "Active" under Webhook
   - Permissions → Repository → Secrets: **Read and write**
2. After creating, click **Install App** in the sidebar and install it on the target pipeline repo only
3. On the App settings page, note the **App ID** and click **Generate a private key**
4. Convert and store the secrets in the `dev` environment (see the key format note in Step 3 above)

---

## Step 4 — Deploy

Two workflows handle deployment:

| Workflow | Trigger | What runs |
|---|---|---|
| **Terraform Apply + Governance** | Push to `terraform/**` | Full Terraform apply → DABs deploy → governance setup job |
| **Deploy Governance Bundle** | Push to `governance/**`, `resources/**`, `databricks.yml` | Terraform outputs only (read-only, ~10s) → DABs deploy → governance setup job |

The split means a governance or dashboard change deploys in under 2 minutes without waiting for a full Terraform apply. The plan workflow runs automatically on any PR targeting `main`.

For a first deploy you can trigger apply manually via GitHub Actions → Terraform Apply → Run workflow.

### Post-deploy manual steps

One thing requires a one-off manual action after each fresh deploy:

1. **Governed tag ASSIGN** — grant `sg-dbplat-governed-tags` at account level via Catalog → Govern → Governed Tags → **Account Permissions** tab. See [docs/governed-tag-grants.md](docs/governed-tag-grants.md).

The account usage dashboard (v2) is created automatically by CI via the Databricks SDK (`UsageDashboardsAPI.create`). No manual import step needed.

---

## Destroying all resources

Go to **GitHub Actions → Terraform Destroy → Run workflow**, then type `destroy-simple` in the confirmation field. The job is skipped entirely if the string doesn't match exactly.

> **Storage soft delete**: Azure storage accounts enable blob soft delete by default. After `terraform destroy`, deleted blobs may be retained for up to 7 days, which can prevent the storage account from being fully removed. If you need an immediate clean teardown, disable soft delete before running destroy:
> ```powershell
> az storage account blob-service-properties update `
>   --account-name dbplatsimpleadls `
>   --resource-group dbplat-simple-rg `
>   --enable-delete-retention false
> ```

---

## Local development

Copy the example vars file and fill in your values:

```powershell
Copy-Item terraform\terraform.tfvars.example terraform\terraform.tfvars
# edit terraform\terraform.tfvars
```

Then authenticate with the Azure CLI and run:

```powershell
az login
cd terraform
terraform init
terraform plan
terraform apply
```

The local run uses Azure CLI credentials rather than OIDC — no additional config needed.

---

## Naming and tagging

All resources use the prefix `dbplat-simple` (configurable via the `prefix` variable). Tags applied to every Azure resource:

| Tag | Value |
|---|---|
| `project` | `simple-databricks-deployment` |
| `environment` | `dev` |
| `owner` | value of `var.owner` |
| `cost-centre` | value of `cost_centre` in `terraform.tfvars` |
| `managed-by` | `terraform` |
