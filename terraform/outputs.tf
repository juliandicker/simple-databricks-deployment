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

output "pipeline_sp_application_id" {
  description = "Application (client) ID of the Travel Data Products Team SP. Used by the TFL pipeline repo as AZURE_CLIENT_ID."
  value       = databricks_service_principal.teams["travel"].application_id
}

output "platform_sp_application_id" {
  description = "Application (client) ID of the data platform admin SP. Used by the governance DABs bundle."
  value       = databricks_service_principal.teams["data_platform_admins"].application_id
}

output "team_warehouse_ids" {
  description = "SQL warehouse IDs by team key."
  value       = { for k, v in databricks_sql_endpoint.team : k => v.id }
}

output "team_sp_application_ids" {
  description = "Application IDs of all team SPs — used to build the ABAC policy EXCEPT clause."
  value       = { for k, v in databricks_service_principal.teams : k => v.application_id }
}
