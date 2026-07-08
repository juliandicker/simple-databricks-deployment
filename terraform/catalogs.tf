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
  # erasure delete there, same as silver/gold. This used to be a dynamic
  # grant here keyed on var.sar_app_sp_id, but that only resolves after the
  # SAR app has been (re)deployed and its SP id copied back into tfvars —
  # a chicken-and-egg problem on every fresh workspace. Moved to
  # databricks-platform-governance's governance_setup job
  # (governance/grant_sar_app_access.py), which already has the app's SP id
  # live via ${resources.apps.sar_app.service_principal_client_id} the
  # moment it deploys, no round-trip through this repo required.

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

  # SAR app SP's SELECT+MODIFY (writes requests/request_items during
  # execution) moved to databricks-platform-governance's governance_setup job
  # (governance/grant_sar_app_access.py) — see the bronze/silver/gold comment
  # above for why.

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

  # SAR app SP's SELECT+MODIFY (writes requests/request_items when a
  # reviewer confirms an access report) moved to
  # databricks-platform-governance's governance_setup job
  # (governance/grant_sar_app_access.py) — see the bronze/silver/gold
  # comment above for why.

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

  # SELECT only, not MODIFY — the app reads this cache at search time, but
  # writes go through the lineage_cache_refresh job (triggered on demand via
  # the app's CAN_MANAGE_RUN job permission, see resources/apps/sar.yml),
  # which runs under its own job identity, not the app SP. The app itself
  # never needs write access here, or any access to system.access.* at all —
  # see apps/sar_app/lineage.py: trigger_lineage_cache_refresh.
  # (SAR app SP's SELECT here moved to databricks-platform-governance's
  # governance_setup job (governance/grant_sar_app_access.py) — see the
  # bronze/silver/gold comment above for why.)

  depends_on = [databricks_schema.team]
}

# system.access is a Unity Catalog system schema — not enabled by default on
# a metastore, per Databricks docs. Since databricks_metastore.this is
# destroyed/recreated every cycle, this must be (re-)enabled every time, not
# just once. databricks_system_schema is a native Terraform resource for
# exactly this (workspace-provider scoped, no metastore_id needed).
resource "databricks_system_schema" "access" {
  provider = databricks.workspace
  schema   = "access"

  depends_on = [databricks_metastore_assignment.this]
}

# governance_setup, governance_daily, and lineage_cache_refresh (see
# resources/jobs/*.yml) all pin run_as to the data_platform_admins team's own
# SP (sp-data-platform, resolved via databricks.yml's platform_sp_id lookup
# variable) — dbplat-simple-github-actions (the CI/OIDC deploy identity) is
# meant only to deploy the bundle, never to execute governance SQL itself.
# That SP already gets ALL PRIVILEGES on admin.lineage_cache above (same
# pattern every team's own schemas use); it also needs this explicit grant
# to read system.access.table_lineage/column_lineage to populate the cache
# — a real, confirmed gap, not a precautionary one: the job failed with
# INSUFFICIENT_PERMISSIONS ("User does not have USE SCHEMA on Schema
# 'system.access'") before this existed. Being an account admin (per
# CLAUDE.md's group-role table) does not automatically bypass this — some
# system schemas require an explicit grant regardless of admin status.
resource "databricks_grants" "system_access" {
  provider = databricks.workspace
  schema   = "system.access"

  grant {
    principal  = databricks_service_principal.teams["data_platform_admins"].application_id
    privileges = ["USE_SCHEMA", "SELECT"]
  }

  depends_on = [databricks_system_schema.access]
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

  # SAR app SP's EXECUTE (to call the two hash UDFs when writing the erasure
  # audit trail) moved to databricks-platform-governance's governance_setup
  # job (governance/grant_sar_app_access.py) — see the bronze/silver/gold
  # comment above for why.

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