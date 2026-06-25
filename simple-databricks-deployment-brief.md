# simple-databricks-deployment — Project Brief & Claude Code Instructions

## 0. Purpose
Seed document for a Claude Code session in this repo. Minimum viable
Databricks-on-Azure lakehouse: cheap, fast to stand up and tear down, built
by reusing official Databricks Terraform examples rather than writing
everything from scratch.

This is the simple counterpart to a separate `enterprise-databricks-deployment`
repo (hardened, multi-environment, private networking). The two are
deliberately separate repos — different CI prerequisites, different
lifecycle, different audience for the "minimum viable" vs. "production
pattern" story. No shared Terraform module between them; a little
duplication is accepted rather than introducing a third shared-modules repo
for two demo-scale projects.

---

## 1. Toolchain decision

**100% Terraform.** No Bicep. Bicep/ARM cannot manage Unity Catalog objects
(catalogs, schemas, external locations, grants) at all — those live in the
Databricks control plane, not ARM — so something needs Terraform (or the
Databricks CLI/SQL) regardless of what manages the Azure resource layer.
Splitting tools would only add a state hand-off with no benefit at this
scale.

State management overhead is addressed operationally, not by switching
tools: remote `azurerm` backend, OIDC auth (no secrets), `terraform plan`
reviewed on every PR, `terraform destroy` as a guarded explicit workflow.

---

## 2. Architecture

### 2.1 Azure resources
- 1x Resource Group
- 1x Azure Databricks workspace (standard SKU, no VNet injection)
- 1x ADLS Gen2 storage account (HNS enabled), containers for `landing`,
  `bronze`, `silver`, `gold`
- 1x Event Hubs namespace, 1 event hub for landing ingestion
- 1x Unity Catalog metastore (if not already assigned), 1 storage
  credential, 1 external location per container
- 4x catalogs (`landing`, `bronze`, `silver`, `gold`), each with a default
  schema

### 2.2 Modules/examples to reuse from `databricks/terraform-databricks-examples`
- `examples/adb-unity-catalog-basic-demo` — metastore, storage credential,
  external location, catalog/schema/grant pattern. Replicate x4.
- `examples/adb-lakehouse` — general workspace + lakehouse blueprint as a
  starting skeleton.
- Event Hub has no upstream Databricks example — plain
  `azurerm_eventhub_namespace` / `azurerm_eventhub`, nothing exotic.

### 2.3 Security/cost posture
- No private endpoints, no VNet injection. IP-allow-list on storage/Event
  Hubs scoped to your IP / GH Actions egress if you want minimal hardening
  without cost.
- Cheapest SKUs throughout, auto-terminate on any test clusters.
- Single environment, single state file, single backend storage account.

### 2.4 Repo structure
```
simple-databricks-deployment/
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── backend.tf            # azurerm backend, OIDC, no secrets
│   ├── providers.tf
│   └── catalogs.tf           # 4x catalog/schema/grant blocks
├── .github/workflows/
│   ├── plan.yml               # on PR
│   ├── apply.yml               # on merge to main
│   └── destroy.yml             # workflow_dispatch only, confirmation input
└── README.md
```

### 2.5 GitHub Actions
- **Auth**: Workload Identity Federation (OIDC) via `azure/login@v2`, no
  stored secrets.
- **plan.yml**: on PR, `terraform plan`, posts as PR comment.
- **apply.yml**: on push to `main`, `terraform apply -auto-approve`.
- **destroy.yml**: `workflow_dispatch` only, requires a typed confirmation
  input (e.g. `confirm: destroy-simple`) checked before proceeding.

---

## 3. Shared conventions

- **Naming**: `dbplat-simple-<resource>` e.g. `dbplat-simple-adls`.
- **Tagging**: `project`, `environment` (`dev` as a nominal tag — single
  env), `owner`, `cost-centre`, `managed-by = terraform`.
- **State backend**: one `azurerm` backend storage account, bootstrapped
  once via a small local-state config or `az cli` script — acknowledge this
  chicken-and-egg step explicitly in the README.
- **Auth**: OIDC/Workload Identity Federation only. No client secrets, no
  standing PATs with Azure permissions stored in GitHub.
- **Provider versions**: pin `databricks` and `azurerm` provider versions
  explicitly.

---

## 4. Definition of done

- [ ] `terraform apply` from a clean GitHub Actions run produces a working
      workspace, storage, Event Hub, and 4 queryable catalogs.
- [ ] `terraform destroy` from GitHub Actions cleanly removes everything,
      no orphaned resources (check storage soft-delete).
- [ ] README documents the OIDC setup and the backend bootstrap step.

---

## 5. Open questions for Claude Code to confirm before scaffolding

1. Any actual ingestion behind the Event Hub (Auto Loader job, Structured
   Streaming notebook), or is it purely structural for now?
2. Target Databricks workspace tier — Premium unlocks full Unity Catalog
   features; confirm whether that's wanted here or Standard is fine given
   this repo's cost-minimisation goal.
