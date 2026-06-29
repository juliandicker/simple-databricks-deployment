locals {
  layers               = ["bronze", "silver", "gold"]
  zones                = concat(local.layers, ["landing"])  # layers + landing; drives catalogs and external locations
  storage_account_name = replace("${var.prefix}adls", "-", "")

  tags = {
    project     = "simple-databricks-deployment"
    environment = "dev"
    owner       = var.owner
    cost-centre = var.cost_centre
    managed-by  = "terraform"
  }
}

resource "azurerm_resource_group" "this" {
  name     = "${var.prefix}-rg"
  location = var.location
  tags     = local.tags
}

resource "azurerm_storage_account" "adls" {
  name                     = local.storage_account_name
  resource_group_name      = azurerm_resource_group.this.name
  location                 = azurerm_resource_group.this.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  is_hns_enabled           = true
  tags                     = local.tags
}

# One container per zone (bronze, silver, gold, landing)
resource "azurerm_storage_container" "data" {
  for_each           = toset(local.zones)
  name               = each.key
  storage_account_id = azurerm_storage_account.adls.id
}

resource "azurerm_storage_management_policy" "landing_purge" {
  storage_account_id = azurerm_storage_account.adls.id

  rule {
    name    = "purge-landing-after-30-days"
    enabled = true
    filters {
      prefix_match = ["landing/"]
      blob_types   = ["blockBlob"]
    }
    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = 30
      }
    }
  }
}

resource "azurerm_storage_container" "metastore" {
  name               = "metastore"
  storage_account_id = azurerm_storage_account.adls.id
}

# Access Connector provides a system-assigned managed identity for Databricks → ADLS auth
resource "azurerm_databricks_access_connector" "unity_catalog" {
  name                = "${var.prefix}-access-connector"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  identity { type = "SystemAssigned" }
  tags = local.tags
}

resource "azurerm_role_assignment" "access_connector_storage" {
  scope                = azurerm_storage_account.adls.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_databricks_access_connector.unity_catalog.identity[0].principal_id
}

resource "azurerm_databricks_workspace" "this" {
  name                = "${var.prefix}-workspace"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "trial"
  tags                = local.tags
}

resource "databricks_metastore" "this" {
  provider      = databricks.accounts
  name          = "${var.prefix}-metastore"
  region        = var.location
  storage_root  = "abfss://metastore@${azurerm_storage_account.adls.name}.dfs.core.windows.net/"
  owner         = databricks_group.this["data_platform_admins"].display_name
  force_destroy = true

  # All Entra group memberships must be complete before any Databricks resource
  # is created. Everything Databricks chains from the metastore, so this single
  # depends_on enforces Entra-first ordering across the entire apply and prevents
  # races where Terraform recreates a Databricks group and wipes AIM-synced members.
  depends_on = [
    azurerm_role_assignment.access_connector_storage,
    azuread_group_member.users,
    azuread_group_member.service_principals,
    azuread_group_member.demo_users,
  ]
}

resource "databricks_metastore_assignment" "this" {
  provider     = databricks.accounts
  metastore_id = databricks_metastore.this.id
  workspace_id = azurerm_databricks_workspace.this.workspace_id
}

resource "databricks_mws_permission_assignment" "this" {
  provider     = databricks.accounts
  for_each     = { for k, v in var.groups : k => v if v.workspace_permission != null }
  workspace_id = azurerm_databricks_workspace.this.workspace_id
  principal_id = databricks_group.this[each.key].id
  permissions  = [each.value.workspace_permission]

  depends_on = [databricks_metastore_assignment.this]
}

resource "databricks_storage_credential" "this" {
  provider = databricks.workspace
  name     = "${var.prefix}-storage-cred"

  azure_managed_identity {
    access_connector_id = azurerm_databricks_access_connector.unity_catalog.id
  }

  force_destroy = true
  depends_on    = [databricks_metastore_assignment.this, databricks_group_member.service_principals_db]
}
