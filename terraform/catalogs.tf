# One external location per zone (bronze, silver, gold, landing)
resource "databricks_external_location" "this" {
  provider        = databricks.workspace
  for_each        = toset(local.zones)
  name            = "${var.prefix}-${each.key}"
  url             = "abfss://${each.key}@${azurerm_storage_account.adls.name}.dfs.core.windows.net/"
  credential_name = databricks_storage_credential.this.name
  force_destroy   = true

  depends_on = [databricks_metastore_assignment.this]
}

resource "databricks_catalog" "this" {
  provider      = databricks.workspace
  for_each      = toset(local.zones)
  name          = each.key
  comment       = "${title(each.key)} catalog"
  storage_root  = "abfss://${each.key}@${azurerm_storage_account.adls.name}.dfs.core.windows.net/"
  force_destroy = true

  depends_on = [databricks_external_location.this]
}

# Default schema for data layers only — landing uses a raw schema backed by external volumes
resource "databricks_schema" "default" {
  provider      = databricks.workspace
  for_each      = toset(local.layers)
  catalog_name  = databricks_catalog.this[each.key].name
  name          = "default"
  force_destroy = true
}


# Admin catalog — shared governance infrastructure (masking UDFs).
# Managed catalog: no ADLS container or external location needed.
resource "databricks_catalog" "admin" {
  provider      = databricks.workspace
  name          = "admin"
  comment       = "Shared governance infrastructure — masking UDFs referenced by ABAC policies across data catalogs"
  force_destroy = true

  depends_on = [databricks_metastore_assignment.this]
}

resource "databricks_schema" "admin_shared" {
  provider      = databricks.workspace
  catalog_name  = databricks_catalog.admin.name
  name          = "shared"
  force_destroy = true
}

locals {
  # All zones get account users navigation access; admin is restricted to data_platform_admins only.
  # Team SPs get schema-level ALL PRIVILEGES via databricks_grants.team_schema in data-product-teams.tf.
  catalog_grants = merge(
    { for z in local.zones : z => { account_users = true } },
    { admin = { account_users = true } }
  )

  # All catalogs in one map: zones → databricks_catalog.this, admin → its own resource.
  _catalog_name = merge(
    { for k in local.zones : k => databricks_catalog.this[k].name },
    { admin = databricks_catalog.admin.name }
  )
}

resource "databricks_grants" "catalog" {
  provider = databricks.workspace
  for_each = local.catalog_grants
  catalog  = local._catalog_name[each.key]

  dynamic "grant" {
    for_each = each.value.account_users ? [1] : []
    content {
      principal  = "account users"
      privileges = ["USE_CATALOG", "USE_SCHEMA"]
    }
  }

  # Team SPs get full ownership of admin so they can deploy and execute shared functions (masking UDFs).
  dynamic "grant" {
    for_each = each.key == "admin" ? var.data_product_teams : {}
    content {
      principal  = databricks_service_principal.teams[grant.key].application_id
      privileges = ["ALL PRIVILEGES", "MANAGE"]
    }
  }

  grant {
    principal  = databricks_group.this["data_platform_admins"].display_name
    privileges = ["ALL PRIVILEGES", "MANAGE"]
  }
}

# Data Classification system governed tags — all team SPs need ASSIGN so they can
# apply class.* tags to their own columns during governance setup.
# NOTE: governed_tag is a relatively new securable type in the Databricks provider.
# If terraform plan errors here, grant ASSIGN manually in Catalog Explorer →
# Govern → Governed Tags → each tag → Permissions for each SP in team_sp_application_ids.
locals {
  governed_tags = toset([
    "class.name",
    "class.email_address",
    "class.date_of_birth",
    "class.location",
  ])
}

resource "databricks_grants" "governed_tag" {
  provider     = databricks.workspace
  for_each     = local.governed_tags
  governed_tag = each.key

  dynamic "grant" {
    for_each = databricks_service_principal.teams
    content {
      principal  = grant.value.application_id
      privileges = ["ASSIGN"]
    }
  }
}