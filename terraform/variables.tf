variable "subscription_id" {
  type        = string
  description = "Azure subscription ID"
}

variable "tenant_id" {
  type        = string
  description = "Azure tenant (directory) ID"
}

variable "location" {
  type        = string
  default     = "uksouth"
  description = "Azure region for all resources"
}

variable "prefix" {
  type        = string
  default     = "dbplat-simple"
  description = "Naming prefix applied to all resources"
}

variable "owner" {
  type        = string
  description = "Owner tag value (e-mail or team name)"
}

variable "cost_centre" {
  type        = string
  description = "Cost centre tag value"
}

variable "databricks_account_id" {
  type        = string
  description = "Databricks account ID (visible at accounts.azuredatabricks.net)"
}

variable "unity_catalog_admins" {
  type        = list(string)
  default     = []
  description = "Databricks account-level users or groups to grant metastore admin"
}

variable "demo_user_password" {
  type        = string
  sensitive   = true
  description = "Initial password for the three demo users (Norma Redacta, Seymour Cleartext, Stewart Tagger). Must satisfy the tenant's password complexity policy."
}

variable "landing_sources" {
  type        = map(list(string))
  default     = {}
  description = <<-EOT
    Map of landing source name to the Databricks principals (users, groups, or
    service principals) granted READ_VOLUME + WRITE_VOLUME on that source's volume.
    Each source gets its own sub-path: /Volumes/landing/raw/<source>/
    Example:
      landing_sources = {
        salesforce = ["group:sales-engineers"]
        sap        = ["group:finance-team", "servicePrincipal:etl-sp-app-id"]
      }
  EOT
}
