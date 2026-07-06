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


moved {
  from = databricks_external_location.admin
  to   = databricks_external_location.this["admin"]
}

moved {
  from = databricks_catalog.admin
  to   = databricks_catalog.this["admin"]
}

# admin.shared is now owned by the data_platform_admins team like any other
# team schema (see data-product-teams.tf) — the platform team dogfoods the
# same schema/grant mechanism every domain team uses, rather than getting a
# bespoke Terraform resource + a blanket catalog-wide grant no other team gets.
moved {
  from = databricks_schema.admin_shared
  to   = databricks_schema.team["data_platform_admins-admin-shared"]
}

locals {
  # All zones get account users navigation access.
  # Team SPs get schema-level ALL PRIVILEGES via databricks_grants.team_schema in data-product-teams.tf.
  catalog_grants = { for z in local.zones : z => { account_users = true } }

  _catalog_name = { for k in local.zones : k => databricks_catalog.this[k].name }
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

  # SAR app SP needs read+write on bronze/silver/gold alike — it both finds
  # upstream bronze PII via lineage tracing and executes the confirmed
  # erasure delete there, same as silver/gold. Runs as the app's own SP (not
  # the user) so the SP requires explicit grants; no single non-admin
  # principal otherwise has cross-team delete rights, since each team SP
  # only owns its own schemas. (Once bronze-only: a real erasure request
  # found and confirmed a bronze row for deletion, then failed with
  # PERMISSION_DENIED on the actual DELETE because bronze granted SELECT
  # only — the two-phase dry-run check only exercises SELECT, so it can't
  # catch a missing MODIFY grant before the real delete is attempted.)
  dynamic "grant" {
    for_each = contains(["bronze", "silver", "gold"], each.key) && var.sar_app_sp_id != "" ? [1] : []
    content {
      principal  = var.sar_app_sp_id
      privileges = ["USE_CATALOG", "USE_SCHEMA", "SELECT", "MODIFY"]
    }
  }

  grant {
    principal  = databricks_group.this["data_platform_admins"].display_name
    privileges = ["ALL PRIVILEGES", "MANAGE"]
  }
}

# admin.erasure holds the erasure audit trail — owned by the data_platform_admins
# team's SP (same ALL PRIVILEGES+MANAGE every team gets on its own schemas), plus
# data stewards get read-only access to review it, plus the SAR app SP gets
# SELECT+MODIFY since it's the one actually writing requests/request_items rows
# during execution. Kept as its own databricks_grants resource (excluded from
# the generic databricks_grants.team_schema in data-product-teams.tf) since a
# schema can only have one authoritative grants resource and this one needs
# extra principals the generic one doesn't support. No other team gets any
# access here (unlike admin.shared, which every team can use to reference
# masking UDFs in their own policies).
resource "databricks_grants" "admin_erasure" {
  provider = databricks.workspace
  schema   = "admin.erasure"

  grant {
    principal  = databricks_service_principal.teams["data_platform_admins"].application_id
    privileges = ["ALL PRIVILEGES", "MANAGE"]
  }

  grant {
    principal  = databricks_group.this["data_stewards"].display_name
    privileges = ["SELECT"]
  }

  dynamic "grant" {
    for_each = var.sar_app_sp_id != "" ? [1] : []
    content {
      principal  = var.sar_app_sp_id
      privileges = ["SELECT", "MODIFY"]
    }
  }

  depends_on = [databricks_schema.team]
}

# admin.access holds the SAR Article 15 access-report audit trail — same
# shape and rationale as admin_erasure above (own databricks_grants resource,
# excluded from the generic team_schema loop, SAR app SP needs SELECT+MODIFY
# since it's the one writing requests/request_items rows when a reviewer
# confirms an access report). No restorations-equivalent principal needed —
# there's no "undo" concept for a disclosure.
resource "databricks_grants" "admin_access" {
  provider = databricks.workspace
  schema   = "admin.access"

  grant {
    principal  = databricks_service_principal.teams["data_platform_admins"].application_id
    privileges = ["ALL PRIVILEGES", "MANAGE"]
  }

  grant {
    principal  = databricks_group.this["data_stewards"].display_name
    privileges = ["SELECT"]
  }

  dynamic "grant" {
    for_each = var.sar_app_sp_id != "" ? [1] : []
    content {
      principal  = var.sar_app_sp_id
      privileges = ["SELECT", "MODIFY"]
    }
  }

  depends_on = [databricks_schema.team]
}

# admin.lineage_cache holds a deduplicated "latest edge" summary of
# system.access.table_lineage/column_lineage, refreshed incrementally by the
# governance_daily job (see governance/refresh_lineage_cache.sql) instead of
# the SAR app re-aggregating those account-wide event logs from scratch on
# every search — the raw system tables grow with every pipeline run, not just
# with the number of distinct table relationships, so live per-search
# aggregation over a real deployment's full history doesn't scale. The SAR
# app SP reads it for every search (bronze search already requires SP
# escalation for cross-team access, so lineage-cache reads use the same
# identity rather than requiring a separate account-users grant on the admin
# catalog, which is deliberately not given out — see the zones/catalog_grants
# comment above) and writes it via the in-app "refresh lineage cache now"
# button.
resource "databricks_grants" "admin_lineage_cache" {
  provider = databricks.workspace
  schema   = "admin.lineage_cache"

  grant {
    principal  = databricks_service_principal.teams["data_platform_admins"].application_id
    privileges = ["ALL PRIVILEGES", "MANAGE"]
  }

  grant {
    principal  = databricks_group.this["data_stewards"].display_name
    privileges = ["SELECT"]
  }

  dynamic "grant" {
    for_each = var.sar_app_sp_id != "" ? [1] : []
    content {
      principal  = var.sar_app_sp_id
      privileges = ["SELECT", "MODIFY"]
    }
  }

  depends_on = [databricks_schema.team]
}

# admin.shared holds the masking UDFs plus the two SAR-erasure hash UDFs
# (hash_subject_ref, hash_row_key). Only the owning data_platform_admins team
# gets ALL PRIVILEGES (domain team SPs don't need any grant here — column
# mask policy enforcement doesn't require the querying principal to have its
# own EXECUTE on the masking function). The SAR app SP additionally gets
# EXECUTE so it can call the two hash UDFs when writing the erasure audit
# trail. Kept as its own databricks_grants resource for the same reason as
# admin_erasure — excluded from the generic databricks_grants.team_schema
# since it needs an extra principal beyond the owning team.
resource "databricks_grants" "admin_shared" {
  provider = databricks.workspace
  schema   = "admin.shared"

  grant {
    principal  = databricks_service_principal.teams["data_platform_admins"].application_id
    privileges = ["ALL PRIVILEGES", "MANAGE"]
  }

  dynamic "grant" {
    for_each = var.sar_app_sp_id != "" ? [1] : []
    content {
      principal  = var.sar_app_sp_id
      privileges = ["EXECUTE"]
    }
  }

  # admin.shared was previously managed by databricks_grants.team_schema
  # (before this schema was excluded from that for_each, above). Without this,
  # Terraform has no way to know both resources touch the same underlying
  # securable and runs the old one's destroy concurrently with this one's
  # create — confirmed by a real apply failure ("permissions ... have to be
  # [...]" conflict) from exactly that race.
  depends_on = [databricks_grants.team_schema, databricks_schema.team]
}

# Governed tag ASSIGN grants are not supported by databricks_grants in the current provider.
# They are applied automatically via the governance DABs job (grant_governed_tags task),
# which runs governance/grant_governed_tags.sql — a file generated by CI from
# terraform output team_sp_application_ids. No manual action required.