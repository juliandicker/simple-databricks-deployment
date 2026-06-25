output "workspace_url" {
  description = "Databricks workspace URL"
  value       = azurerm_databricks_workspace.this.workspace_url
}

output "workspace_id" {
  description = "Databricks workspace ID (numeric)"
  value       = azurerm_databricks_workspace.this.workspace_id
}

output "storage_account_name" {
  description = "ADLS Gen2 storage account name"
  value       = azurerm_storage_account.adls.name
}

output "metastore_id" {
  description = "Unity Catalog metastore ID"
  value       = databricks_metastore.this.id
}

output "resource_group_name" {
  description = "Azure resource group name"
  value       = azurerm_resource_group.this.name
}
