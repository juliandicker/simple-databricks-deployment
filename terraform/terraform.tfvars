cost_centre = "CC-500"

# SAR app service principal — auto-created by Databricks Apps on first deploy.
# Update this value if the app is recreated on a fresh workspace (terraform destroy + apply),
# or (as happened during the infra/governance repo split) if the app itself is deleted and
# recreated under a different deploying bundle.
sar_app_sp_id = "35270d78-cb8c-4daa-87e0-6eec2fb5d8a7"

# CI/OIDC deploy service principal (dbplat-simple-github-actions) — created by
# scripts/oidc-setup.ps1, not managed by Terraform. Stable across
# destroy/apply cycles (unlike sar_app_sp_id) since it's an Azure AD app
# registration, not something Databricks Apps recreates. Only used to grant
# it the servicePrincipal.user role on sp-data-platform (see
# databricks_access_control_rule_set.ci_deploy_sp_can_use_platform_sp in
# data-product-teams.tf) — never direct data-plane access.
ci_deploy_sp_id = "46c06417-ca50-4320-9465-1b7ff082587f"

groups = {
  data_platform_admins = {
    display_name         = "sg-dbplat-data-platform-admins"
    databricks_roles     = ["account_admin"]
    workspace_permission = "ADMIN"
    inject_owner         = true   # merges TF_VAR_owner into this group's users at plan time
  }
  data_stewards = {
    display_name         = "sg-dbplat-data-stewards"
    workspace_permission = "USER"
  }
  pii_readers = {
    display_name         = "sg-dbplat-pii-readers"
    workspace_permission = "USER"
  }
  standard_readers = {
    display_name         = "sg-dbplat-standard-readers"
    workspace_permission = "USER"
  }
  data_product_sps = {
    display_name = "sg-dbplat-data-product-sps"
    # No workspace_permission — team SPs register individually via databricks_service_principal.teams.
    # This group holds all domain team SPs; it is nested inside governed_tags below.
  }
  governed_tags = {
    display_name = "sg-dbplat-governed-tags"
    # Nests data_product_sps + data_stewards — see groups.tf for the membership resources.
    # Only this group needs to be granted ASSIGN on governed tags (docs/governed-tag-grants.md).
  }
}

data_product_teams = {
  data_platform_admins = {
    display_name          = "sp-data-platform"
    platform_team         = true
    cost_centre           = "CC-100"
    sp_github_repo        = "juliandicker/databricks-platform-governance"
    sp_github_environment = "dev"
    schemas = {
      admin = ["shared", "erasure", "access", "lineage_cache"]
    }
    budget = {
      enabled             = true
      alert_threshold_usd = 500
      alert_email         = "julian@redkic.co.uk"
    }
  }
  travel = {
    display_name          = "sp-travel-data-products"
    cost_centre           = "CC-210"
    sp_github_repo        = "juliandicker/tfl-disruption-data-pipeline"
    sp_github_environment = "dev"
    landing_sources = ["tfl"]
    schemas = {
      landing = ["travel"]
      bronze  = ["tfl"]
      silver  = ["tfl"]
      gold    = ["travel"]
    }
    budget = {
      enabled             = true
      alert_threshold_usd = 200
      alert_email         = "julian@redkic.co.uk"
    }
  }
}

platform_budget = {
  enabled             = true
  alert_threshold_usd = 1000
  alert_email         = "julian@redkic.co.uk"
}

group_members = {
  data_platform_admins = {
    service_principals = ["dbplat-simple-github-actions"]
  }
}

demo_users = {
  norma_redacta = {
    display_name  = "Norma Redacta"
    mail_nickname = "norma.redacta"
    group_key     = "standard_readers"
  }
  seymour_cleartext = {
    display_name  = "Seymour Cleartext"
    mail_nickname = "seymour.cleartext"
    group_key     = "pii_readers"
  }
  stewart_tagger = {
    display_name  = "Stewart Tagger"
    mail_nickname = "stewart.tagger"
    group_key     = "data_stewards"
  }
}
