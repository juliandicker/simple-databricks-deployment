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

# Grant all workspace users read access to every catalog; tighten per environment as needed
resource "databricks_grants" "catalog" {
  provider = databricks.workspace
  for_each = toset(local.layers)
  catalog  = databricks_catalog.this[each.key].name

  grant {
    principal  = "account users"
    privileges = ["USE_CATALOG", "USE_SCHEMA", "SELECT"]
  }
}

# Landing: catalog with no storage_root (no Delta tables), a raw schema, and an external volume
resource "databricks_catalog" "landing" {
  provider      = databricks.workspace
  name          = "landing"
  comment       = "Landing zone — raw files only via Unity Catalog volume, no Delta tables"
  force_destroy = true

  depends_on = [databricks_external_location.landing]
}

resource "databricks_schema" "landing_raw" {
  provider      = databricks.workspace
  catalog_name  = databricks_catalog.landing.name
  name          = "raw"
  force_destroy = true
}

resource "databricks_volume" "landing_raw" {
  provider         = databricks.workspace
  name             = "files"
  catalog_name     = databricks_catalog.landing.name
  schema_name      = databricks_schema.landing_raw.name
  volume_type      = "EXTERNAL"
  storage_location = "abfss://landing@${azurerm_storage_account.adls.name}.dfs.core.windows.net/"
  comment          = "Raw file drop zone; blobs purged after 30 days by Azure lifecycle policy"
  force_destroy    = true

  depends_on = [databricks_external_location.landing]
}

resource "databricks_grants" "landing_catalog" {
  provider = databricks.workspace
  catalog  = databricks_catalog.landing.name

  grant {
    principal  = "account users"
    privileges = ["USE_CATALOG", "USE_SCHEMA"]
  }
}

resource "databricks_grants" "landing_volume" {
  provider = databricks.workspace
  volume   = "${databricks_catalog.landing.name}.${databricks_schema.landing_raw.name}.${databricks_volume.landing_raw.name}"

  grant {
    principal  = "account users"
    privileges = ["READ_VOLUME", "WRITE_VOLUME"]
  }
}
