# simple-databricks-deployment

Minimum viable Databricks lakehouse on Azure. One workspace, ADLS Gen2, Unity Catalog (landing raw-file zone + bronze/silver/gold Delta layers), deployed entirely via Terraform with OIDC auth and no stored secrets.

This is the **infra** half of a two-repo split. It owns everything Terraform-manageable — the workspace, storage, metastore, Unity Catalog catalogs/schemas/grants, groups, and data-mesh team service principals. ABAC masking policies, GDPR audit tables, the SAR app, and the DABs jobs that maintain them live in [`databricks-platform-governance`](https://github.com/juliandicker/databricks-platform-governance), which has no Terraform of its own — see "Governance repo" below for how the two connect. The split exists so a future, differently-architected infra project (e.g. VNet-injected) can reuse the same governance repo unchanged.

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
    ├── Catalog: admin    → schemas: shared / erasure / access / lineage_cache (shells created
    │                        here; masking UDFs, ABAC policies, and audit tables populated by
    │                        databricks-platform-governance's jobs)
    ├── Catalog: landing  → schema: raw → volume: <source>  (one per team source)
    ├── Catalog: bronze   → schema: default, <team schemas>
    ├── Catalog: silver   → schema: default, <team schemas>  + ABAC column masks (policy
    │                        definitions live in databricks-platform-governance)
    └── Catalog: gold     → schema: default, <team schemas>  + ABAC column masks (ditto)

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
├── sg-dbplat-data-product-sps      → every domain team SP, sp-data-platform, and the SAR app's
│                                      own SP — nested inside governed-tags, and referenced by
│                                      name as the ABAC mask-exemption group in the governance repo
└── sg-dbplat-governed-tags         → single principal for ASSIGN on 18 governed tags
    ├── sg-dbplat-data-product-sps  (nested)
    └── sg-dbplat-data-stewards     (nested)
```

## Documentation

Each functional area has its own doc:

| Doc | Covers |
|---|---|
| [docs/access-and-pii-governance.md](docs/access-and-pii-governance.md) | Catalog grants, Entra groups/AIM (this repo) — ABAC column masking policy definitions and the Access Audit dashboard now live in `databricks-platform-governance` |
| [docs/data-lifecycle-governance.md](docs/data-lifecycle-governance.md) | Platform metadata columns, freshness SLAs, retention (this repo) — the governance jobs and Data Governance dashboard that act on them now live in `databricks-platform-governance` |
| [docs/data-product-teams.md](docs/data-product-teams.md) | Data mesh team model, SQL warehouses, serverless cost governance/budgets, landing zone |

The SAR app, its docs, and the governed-tag-grants procedure moved to [`databricks-platform-governance`'s docs/](https://github.com/juliandicker/databricks-platform-governance/tree/main/docs).

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

The apply workflow automatically pushes `AZURE_CLIENT_ID` and `DATABRICKS_HOST` to two downstream repos after each apply: the data pipeline repo (team SP) and `databricks-platform-governance` (`sp-data-platform`, which that repo's own CI authenticates as via OIDC). This uses a GitHub App rather than a PAT — no expiry and scoped only to the target repos.

1. Go to **github.com → profile → Settings → Developer settings → GitHub Apps → New GitHub App**
   - Set any homepage URL (e.g. your GitHub profile)
   - Uncheck "Active" under Webhook
   - Permissions → Repository → Secrets: **Read and write**
2. After creating, click **Install App** in the sidebar and install it on each target repo — adding a new target repo later (e.g. a new pipeline, or if you rename `databricks-platform-governance`) means coming back here and adding it, since this isn't available via a regular user's `gh`/API token
3. On the App settings page, note the **App ID** and click **Generate a private key**
4. Convert and store the secrets in the `dev` environment (see the key format note in Step 3 above)

---

## Step 4 — Deploy

This repo has one deploy workflow now:

| Workflow | Trigger | What runs |
|---|---|---|
| **Terraform Apply** | Push to `terraform/**` | Terraform apply → enable data classification → push cross-repo secrets → create account usage dashboard |

Terraform apply no longer waits for or triggers a DABs bundle deploy — that happens entirely in [`databricks-platform-governance`](https://github.com/juliandicker/databricks-platform-governance)'s own CI, triggered by pushes to that repo (or a manual `workflow_dispatch` there). The plan workflow runs automatically on any PR targeting `main`.

For a first deploy you can trigger apply manually via GitHub Actions → Terraform Apply → Run workflow. Once it succeeds, do a first manual deploy of the governance repo too (Actions → Deploy Governance Bundle → Run workflow there) — its config resolves fresh against the live workspace on every deploy, so it doesn't need re-triggering from here afterward.

### Post-deploy manual steps

One thing requires a one-off manual action after each fresh deploy, done from the governance repo (see its docs):

1. **Governed tag ASSIGN** — grant `sg-dbplat-governed-tags` at account level via Catalog → Govern → Governed Tags → **Account Permissions** tab.

The account usage dashboard (v2) is created automatically by this repo's CI via the Databricks SDK (`UsageDashboardsAPI.create`). No manual import step needed.

---

## Destroying all resources

Go to **GitHub Actions → Terraform Destroy → Run workflow**, then type `destroy-simple` in the confirmation field. The job is skipped entirely if the string doesn't match exactly.

> **SAR app SP grant**: The SAR app gets a new service principal every time the workspace is recreated (or the app object is deleted and redeployed from `databricks-platform-governance`'s bundle). After redeploying, update `sar_app_sp_id` in `terraform/terraform.tfvars` with the new application ID and run `terraform apply` to restore its bronze/silver/gold grants and `sg-dbplat-data-product-sps` membership.

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

## Governance repo

[`databricks-platform-governance`](https://github.com/juliandicker/databricks-platform-governance) has no Terraform of its own — ABAC masking policies and UDFs, GDPR audit tables, the SAR app, and the DABs jobs that maintain all of it live there, deployed by its own CI authenticated as `sp-data-platform` via OIDC. It's enabled from this repo exactly the way a downstream pipeline repo is (Step 3b above): Terraform creates `sp-data-platform` and its federated credential scoped to that repo (`data_product_teams.data_platform_admins.sp_github_repo` in `terraform.tfvars`), and every apply pushes `AZURE_CLIENT_ID`/`DATABRICKS_HOST` into it as secrets. See that repo's own README/CLAUDE.md for its layout and local dev (the SAR app's `run-sar-app-local.ps1` script now lives there too).

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
