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
    privileges = ["ALL PRIVILEGES", "MANAGE"]
  }

  grant {
    principal  = databricks_group.this["data_platform_admins"].display_name
    privileges = ["ALL PRIVILEGES", "MANAGE"]
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
    privileges = ["ALL PRIVILEGES", "MANAGE"]
  }

  grant {
    principal  = databricks_group.this["data_platform_admins"].display_name
    privileges = ["ALL PRIVILEGES", "MANAGE"]
  }
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

resource "databricks_grants" "admin" {
  provider = databricks.workspace
  catalog  = databricks_catalog.admin.name

  grant {
    principal  = databricks_service_principal.this["pipeline"].application_id
    privileges = ["ALL PRIVILEGES", "MANAGE"]
  }

  grant {
    principal  = databricks_group.this["data_platform_admins"].display_name
    privileges = ["ALL PRIVILEGES", "MANAGE"]
  }
}

# Data Classification is enabled on silver and gold catalogs by the
# "Enable Data Classification" CI step in apply.yml. The engine auto-tags
# PII columns with class.* system governed tags within ~24 h of scanning.
# Column-level tag bootstrapping (for the window before the engine runs)
# is handled by the tfl pipeline's deploy workflow once ASSIGN is granted below.

# Grant ASSIGN on class.* governed tags to the pipeline SP.
resource "databricks_grants" "class_tag_assign" {
  provider     = databricks.workspace
  for_each     = toset(["class.name", "class.email_address", "class.date_of_birth", "class.location"])
  governed_tag = each.key

  grant {
    principal  = databricks_service_principal.this["pipeline"].application_id
    privileges = ["ASSIGN"]
  }
}

# USE_CATALOG + USE_SCHEMA lets principals navigate to the catalog without granting data access
resource "databricks_grants" "landing_catalog" {
  provider = databricks.workspace
  catalog  = databricks_catalog.landing.name

  grant {
    principal  = "account users"
    privileges = ["USE_CATALOG", "USE_SCHEMA"]
  }

  grant {
    principal  = databricks_group.this["data_platform_admins"].display_name
    privileges = ["ALL PRIVILEGES", "MANAGE"]
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
