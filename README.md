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

## Documentation

Each functional area has its own doc:

| Doc | Covers |
|---|---|
| [docs/access-and-pii-governance.md](docs/access-and-pii-governance.md) | Catalog grants, ABAC column masking, governed tags, Entra groups/AIM, Access Audit dashboard |
| [docs/data-lifecycle-governance.md](docs/data-lifecycle-governance.md) | Platform metadata columns, freshness SLAs, Auto TTL/retention, governance jobs, Data Governance dashboard |
| [docs/data-product-teams.md](docs/data-product-teams.md) | Data mesh team model, SQL warehouses, serverless cost governance/budgets, landing zone |
| [docs/sar-app.md](docs/sar-app.md) | GDPR Subject Access Request search + erasure app (all-or-nothing delete, time-travel restore), idle auto-stop |

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

> **SAR app SP grant**: The SAR app gets a new service principal every time the workspace is recreated. After redeploying, update `sar_app_sp_id` in `terraform/terraform.tfvars` with the new application ID (see [docs/sar-app.md](docs/sar-app.md)) and run `terraform apply` to restore `SELECT` on bronze.

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
