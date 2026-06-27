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
│   └── container: gold
├── Databricks Access Connector (managed identity → Storage Blob Data Contributor)
└── Databricks Workspace (Premium SKU)

Unity Catalog (account-level)
└── Metastore (owner: data-platform-admins) → assigned to workspace
    ├── Storage Credential (access connector managed identity)
    ├── External Location: landing
    ├── External Location: bronze
    ├── External Location: silver
    ├── External Location: gold
    ├── Catalog: landing  → schema: raw → volume: <source>  (one per source, external)
    ├── Catalog: bronze   → schema: default
    ├── Catalog: silver   → schema: default
    └── Catalog: gold     → schema: default

Entra ID security groups (synced to Databricks account via AIM)
├── sg-dbplat-data-platform-admins  → Databricks: account admin, metastore owner, workspace ADMIN
├── sg-dbplat-data-stewards         → Databricks: workspace USER
├── sg-dbplat-pii-readers           → Databricks: workspace USER
└── sg-dbplat-standard-readers      → Databricks: workspace USER
```

### Catalog access

Access follows a data mesh principle — all account users can browse every layer:

| Catalog | Account users | Pipeline SP |
|---|---|---|
| `landing` | `USE_CATALOG`, `USE_SCHEMA` | `ALL PRIVILEGES` |
| `bronze` | `USE_CATALOG`, `USE_SCHEMA` | `ALL PRIVILEGES` |
| `silver` | `USE_CATALOG`, `USE_SCHEMA`, `SELECT` | `ALL PRIVILEGES` |
| `gold` | `USE_CATALOG`, `USE_SCHEMA`, `SELECT` | `ALL PRIVILEGES` |

Bronze is intentionally browse-only for account users — data access requires the pipeline SP. Silver and gold are read-accessible to all users.

### Groups and access governance

Four Entra security groups govern access. Terraform creates them and manages membership; Databricks mirrors them via AIM (Automatic Identity Management):

| Entra group | Databricks role | Purpose |
|---|---|---|
| `sg-dbplat-data-platform-admins` | Account admin, metastore owner, workspace ADMIN | Platform operators |
| `sg-dbplat-data-stewards` | Workspace USER | Data quality and ownership |
| `sg-dbplat-pii-readers` | Workspace USER | Access to PII-tagged columns |
| `sg-dbplat-standard-readers` | Workspace USER | Standard read access |

The `data-platform-admins` group is seeded with the owner specified in the `OWNER` secret. Additional members are added in Entra and AIM propagates them to Databricks automatically.

> **AIM and Terraform**: AIM can race against `terraform apply` when creating the Databricks mirror group for `data_platform_admins`. If an apply fails with "Group already exists", it means AIM synced the group before Terraform could create it. Delete the Databricks group from the account console, then re-run the apply immediately before AIM re-syncs.

### Landing zone

Landing is a raw file drop zone — CSV, JSON, Parquet, etc. Files are purged automatically after 30 days by an Azure lifecycle policy. No Delta tables are created here.

Each data source gets its own Unity Catalog external volume at `/Volumes/landing/raw/<source>/` with access locked to the principals you specify. Define sources in `terraform.tfvars`:

```hcl
landing_sources = {
  salesforce = ["group:sales-engineers"]
  sap        = ["group:finance-team", "servicePrincipal:<app-id>"]
}
```

Adding a new source is a one-line tfvars change — no Terraform code changes needed. Principals can be Databricks account users (`user:name@example.com`), groups (`group:name`), or service principals (`servicePrincipal:<application-id>`).

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
| `COST_CENTRE` | Cost centre tag value |
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

The apply workflow automatically pushes `AZURE_CLIENT_ID` (pipeline SP) and `DATABRICKS_HOST` (workspace URL) to any downstream pipeline repo after each apply. This uses a GitHub App rather than a PAT — no expiry and scoped only to the target repo.

1. Go to **github.com → profile → Settings → Developer settings → GitHub Apps → New GitHub App**
   - Set any homepage URL (e.g. your GitHub profile)
   - Uncheck "Active" under Webhook
   - Permissions → Repository → Secrets: **Read and write**
2. After creating, click **Install App** in the sidebar and install it on the target pipeline repo only
3. On the App settings page, note the **App ID** and click **Generate a private key**
4. Convert and store the secrets in the `dev` environment (see the key format note in Step 3 above)

---

## Step 4 — Deploy

Push a commit to `main` that touches anything under `terraform/` and the apply workflow will run. The plan workflow runs automatically on any PR targeting `main`.

For a first deploy you can trigger apply manually via GitHub Actions → Terraform Apply → Run workflow.

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
| `cost-centre` | value of `var.cost_centre` |
| `managed-by` | `terraform` |
