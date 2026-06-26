terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.60"
    }
  }
}

provider "azurerm" {
  features {}
  use_oidc        = true
  subscription_id = var.subscription_id
}

# Entra ID — creates security groups for pipeline ABAC governance.
# The GitHub Actions service principal needs the Microsoft Graph
# Group.ReadWrite.All application permission to create/manage groups.
# Grant it in Entra: App registrations -> dbplat-simple-github-actions
# -> API permissions -> Add -> Microsoft Graph -> Application -> Group.ReadWrite.All
provider "azuread" {
  use_oidc  = true
  tenant_id = var.tenant_id
}

# Account-level: creates and assigns the Unity Catalog metastore
provider "databricks" {
  alias      = "accounts"
  host       = "https://accounts.azuredatabricks.net"
  account_id = var.databricks_account_id
  # Auth via ARM_CLIENT_ID / ARM_TENANT_ID / ARM_USE_OIDC env vars set in CI
}

# Workspace-level: creates UC objects (catalogs, schemas, grants, locations)
provider "databricks" {
  alias = "workspace"
  host  = azurerm_databricks_workspace.this.workspace_url
  # Auth via ARM_CLIENT_ID / ARM_TENANT_ID / ARM_USE_OIDC env vars set in CI
}
