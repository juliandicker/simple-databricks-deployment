# One external location per lakehouse layer, each backed by its ADLS container
resource "databricks_external_location" "this" {
  provider        = databricks.workspace
  for_each        = toset(local.layers)
  name            = "${var.prefix}-${each.key}"
  url             = "abfss://${each.key}@${azurerm_storage_account.adls.name}.dfs.core.windows.net/"
  credential_name = databricks_storage_credential.this.name
  force_destroy   = true

  depends_on = [databricks_metastore_assignment.this]
}

# Landing gets its own external location (removed from the for_each when landing left local.layers)
moved {
  from = databricks_external_location.this["landing"]
  to   = databricks_external_location.landing
}

resource "databricks_external_location" "landing" {
  provider        = databricks.workspace
  name            = "${var.prefix}-landing"
  url             = "abfss://landing@${azurerm_storage_account.adls.name}.dfs.core.windows.net/"
  credential_name = databricks_storage_credential.this.name
  force_destroy   = true

  depends_on = [databricks_metastore_assignment.this]
}

resource "databricks_catalog" "this" {
  provider      = databricks.workspace
  for_each      = toset(local.layers)
  name          = each.key
  comment       = "${title(each.key)} layer catalog"
  storage_root  = "abfss://${each.key}@${azurerm_storage_account.adls.name}.dfs.core.windows.net/"
  force_destroy = true

  depends_on = [databricks_external_location.this]
}

resource "databricks_schema" "default" {
  provider      = databricks.workspace
  for_each      = toset(local.layers)
  catalog_name  = databricks_catalog.this[each.key].name
  name          = "default"
  force_destroy = true
}

# All layers: account users can browse; pipeline SP has full ownership.
resource "databricks_grants" "catalog" {
  provider = databricks.workspace
  for_each = toset(["silver", "gold"])
  catalog  = databricks_catalog.this[each.key].name

  grant {
    principal  = "account users"
    privileges = ["USE_CATALOG", "USE_SCHEMA", "SELECT"]
  }

  grant {
    principal  = databricks_service_principal.this["pipeline"].application_id
    privileges = ["ALL PRIVILEGES"]
  }
}

resource "databricks_grants" "bronze" {
  provider = databricks.workspace
  catalog  = databricks_catalog.this["bronze"].name

  grant {
    principal  = "account users"
    privileges = ["USE_CATALOG", "USE_SCHEMA"]
  }

  grant {
    principal  = databricks_service_principal.this["pipeline"].application_id
    privileges = ["ALL PRIVILEGES"]
  }
}

# Rename in state to avoid destroy+recreate collision on the same catalog name
moved {
  from = databricks_catalog.this["landing"]
  to   = databricks_catalog.landing
}

# Landing: storage_root kept (immutable field, matches existing resource); no table-creation
# privileges granted so it stays a file-only zone in practice
resource "databricks_catalog" "landing" {
  provider      = databricks.workspace
  name          = "landing"
  comment       = "Landing zone — raw files only via Unity Catalog volume, no Delta tables"
  storage_root  = "abfss://landing@${azurerm_storage_account.adls.name}.dfs.core.windows.net/"
  force_destroy = true

  depends_on = [databricks_external_location.landing]
}

resource "databricks_schema" "landing_raw" {
  provider      = databricks.workspace
  catalog_name  = databricks_catalog.landing.name
  name          = "raw"
  force_destroy = true
}

resource "databricks_volume" "landing_sources" {
  provider         = databricks.workspace
  for_each         = var.landing_sources
  name             = each.key
  catalog_name     = databricks_catalog.landing.name
  schema_name      = databricks_schema.landing_raw.name
  volume_type      = "EXTERNAL"
  storage_location = "abfss://landing@${azurerm_storage_account.adls.name}.dfs.core.windows.net/raw/${each.key}/"
  comment          = "Landing drop zone for ${each.key}; blobs purged after 30 days"

  depends_on = [databricks_external_location.landing]
}

# USE_CATALOG + USE_SCHEMA lets principals navigate to the catalog without granting data access
resource "databricks_grants" "landing_catalog" {
  provider = databricks.workspace
  catalog  = databricks_catalog.landing.name

  grant {
    principal  = "account users"
    privileges = ["USE_CATALOG", "USE_SCHEMA"]
  }
}

resource "databricks_grants" "landing_sources" {
  provider = databricks.workspace
  for_each = var.landing_sources
  volume   = "${databricks_catalog.landing.name}.${databricks_schema.landing_raw.name}.${each.key}"

  dynamic "grant" {
    for_each = each.value
    content {
      principal  = grant.value
      privileges = ["READ_VOLUME", "WRITE_VOLUME"]
    }
  }

  depends_on = [databricks_volume.landing_sources]
}
