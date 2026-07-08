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
      version = "~> 1.69"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }
}

provider "azurerm" {
  features {}
  use_oidc        = true
  subscription_id = var.subscription_id
}

# Entra ID — creates security groups, demo users, and group memberships.
# The GitHub Actions service principal needs three Microsoft Graph application
# permissions (granted and consented by scripts/oidc-setup.ps1):
#   Group.ReadWrite.All  — azuread_group, azuread_group_member
#   User.ReadWrite.All   — azuread_user
#   Domain.Read.All      — data.azuread_domains
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
