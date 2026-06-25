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
