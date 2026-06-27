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

variable "groups" {
  description = "Entra security groups and their Databricks config. Add a new entry to provision a group end-to-end."
  type = map(object({
    display_name         = string
    databricks_roles     = optional(list(string), [])
    workspace_permission = optional(string)
    inject_owner         = optional(bool, false)
  }))
}

variable "group_members" {
  description = "Members for each group key: existing user UPNs and service principal display names."
  type = map(object({
    user_upns          = optional(list(string), [])
    service_principals = optional(list(string), [])
  }))
  default = {}
}

variable "demo_users" {
  description = "Managed demo users to create in Entra and assign to a group by key."
  type = map(object({
    display_name  = string
    mail_nickname = string
    group_key     = string
  }))
  default = {}
}

variable "demo_user_password" {
  type        = string
  sensitive   = true
  description = "Initial password for the three demo users (Norma Redacta, Seymour Cleartext, Stewart Tagger). Must satisfy the tenant's password complexity policy."
}

variable "service_principals" {
  description = "Service principals to create in Entra and register in Databricks. Each entry creates an app registration, service principal, optional GitHub OIDC federated credential, and Databricks workspace registration."
  type = map(object({
    display_name       = string
    github_repo        = optional(string)        # "org/repo" — if set, creates a GitHub OIDC federated credential
    github_environment = optional(string, "dev")
  }))
  default = {}
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
