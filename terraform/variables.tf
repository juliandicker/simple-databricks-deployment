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
  default     = "northeurope"
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

variable "data_product_teams" {
  type = map(object({
    display_name          = string
    sp_github_repo        = optional(string)
    sp_github_environment = optional(string, "dev")
    landing_sources       = optional(list(string), [])
    schemas               = optional(map(list(string)), {})
    platform_team         = optional(bool, false)
    warehouse = optional(object({
      cluster_size     = optional(string, "2X-Small")
      min_num_clusters = optional(number, 1)
      max_num_clusters = optional(number, 1)
      auto_stop_mins   = optional(number, 10)
      serverless       = optional(bool, true)
    }), {})
  }))
  default     = {}
  description = <<-EOT
    Data mesh domain teams. Each team key maps to a domain (e.g. "travel", "music").
    A team owns one service principal and one or more data products (schemas + landing volumes).
    landing_sources: volume names in landing.raw — one per source system ingested by this team.
    schemas: map of layer → schema names. bronze/silver are typically source-named; gold is
    domain-named to reflect that gold publishes merged data products for consumers.
    Adding a data product to a team, or adding a new domain team, requires only a tfvars change.
    Example:
      data_product_teams = {
        travel = {
          display_name    = "sp-travel-data-products"
          sp_github_repo  = "org/travel-pipeline"
          landing_sources = ["tfl", "british_airways"]
          schemas = {
            landing = ["travel"]
            bronze  = ["tfl", "british_airways"]
            silver  = ["tfl", "british_airways"]
            gold    = ["travel"]
          }
        }
        music = {
          display_name    = "sp-music-data-products"
          landing_sources = ["spotify"]
          schemas = {
            landing = ["music"]
            bronze  = ["spotify"]
            silver  = ["spotify"]
            gold    = ["music"]
          }
        }
      }
  EOT
}
