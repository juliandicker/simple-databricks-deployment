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
}

service_principals = {
  pipeline = {
    display_name       = "sp-tfl-pipeline"
    github_repo        = "juliandicker/tfl-disruption-data-pipeline"
    github_environment = "dev"
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
