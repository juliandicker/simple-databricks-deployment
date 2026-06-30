cost_centre = "data-eng"

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
    display_name  = "sp-data-platform"
    platform_team = true
    cost_centre   = "CC-100"
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
  }
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
