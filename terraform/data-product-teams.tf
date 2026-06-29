# ---------------------------------------------------------------------------
# Data mesh domain teams.
# Each team owns a service principal, schemas in every medallion layer, and
# landing volumes for the source systems they ingest.
# To add a new team or a new data product within a team, edit terraform.tfvars only.
# ---------------------------------------------------------------------------

locals {
  # Flat map: one entry per (team × layer × schema_name).
  # Keys: "${team_key}-${layer}-${schema_name}" e.g. "travel-bronze-tfl", "travel-gold-travel"
  # Iterates team.schemas directly so teams define their own layer keys (bronze/silver/gold only —
  # landing uses volumes, not schemas, so it never appears in team.schemas).
  team_layer_schemas = {
    for triple in flatten([
      for team_key, team in var.data_product_teams : [
        for layer, schema_names in team.schemas : [
          for schema_name in schema_names : {
            key      = "${team_key}-${layer}-${schema_name}"
            team_key = team_key
            layer    = layer
            schema   = schema_name
          }
        ]
      ]
    ]) : triple.key => triple
  }

  # Flat map: one entry per (team × landing_source).
  # Keys: "${team_key}-${source}" e.g. "travel-tfl"
  # landing_schema is the team's schema in the landing catalog (e.g. "travel"),
  # taken from schemas["landing"][0] — teams with landing_sources must define schemas["landing"].
  team_landing_sources = {
    for pair in flatten([
      for team_key, team in var.data_product_teams : [
        for source in team.landing_sources : {
          key            = "${team_key}-${source}"
          team_key       = team_key
          source         = source
          landing_schema = team.schemas["landing"][0]
        }
      ]
    ]) : pair.key => pair
  }

  team_sp_github_creds = {
    for k, v in var.data_product_teams : k => v
    if v.sp_github_repo != null
  }
}

# One Entra application per team.
resource "azuread_application" "teams" {
  for_each     = var.data_product_teams
  display_name = each.value.display_name
}

resource "azuread_service_principal" "teams" {
  for_each  = var.data_product_teams
  client_id = azuread_application.teams[each.key].client_id
}

# GitHub OIDC federated credential — lets the team's pipeline authenticate without stored secrets.
resource "azuread_application_federated_identity_credential" "teams" {
  for_each       = local.team_sp_github_creds
  application_id = azuread_application.teams[each.key].id
  display_name   = "github-actions-${each.key}-${each.value.sp_github_environment}"
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${each.value.sp_github_repo}:environment:${each.value.sp_github_environment}"
  audiences      = ["api://AzureADTokenExchange"]
}

# Register in Databricks workspace (also makes SP visible at account level for UC grants).
resource "databricks_service_principal" "teams" {
  provider       = databricks.workspace
  for_each       = var.data_product_teams
  application_id = azuread_service_principal.teams[each.key].client_id
  display_name   = azuread_application.teams[each.key].display_name

  depends_on = [databricks_metastore_assignment.this]
}

# One schema per (team × layer × schema_name).
# Teams are locked to their own schemas; the account users grant covers catalog navigation.
resource "databricks_schema" "team" {
  provider      = databricks.workspace
  for_each      = local.team_layer_schemas
  catalog_name  = databricks_catalog.this[each.value.layer].name
  name          = each.value.schema
  force_destroy = true
}

resource "databricks_grants" "team_schema" {
  provider = databricks.workspace
  for_each = local.team_layer_schemas
  schema   = "${each.value.layer}.${each.value.schema}"

  grant {
    principal  = databricks_service_principal.teams[each.value.team_key].application_id
    privileges = ["ALL PRIVILEGES", "MANAGE"]
  }

  depends_on = [databricks_schema.team]
}

# One external volume per (team × landing_source).
resource "databricks_volume" "team_landing" {
  provider         = databricks.workspace
  for_each         = local.team_landing_sources
  name             = each.value.source
  catalog_name     = databricks_catalog.this["landing"].name
  schema_name      = databricks_schema.team["${each.value.team_key}-landing-${each.value.landing_schema}"].name
  volume_type      = "EXTERNAL"
  storage_location = "abfss://landing@${azurerm_storage_account.adls.name}.dfs.core.windows.net/raw/${each.value.source}/"
  comment          = "Landing drop zone for ${each.value.source} (${each.value.team_key} team); blobs purged after 30 days"
}

resource "databricks_grants" "team_landing" {
  provider = databricks.workspace
  for_each = local.team_landing_sources
  volume   = "${databricks_catalog.this["landing"].name}.${each.value.landing_schema}.${each.value.source}"

  grant {
    principal  = databricks_service_principal.teams[each.value.team_key].application_id
    privileges = ["READ_VOLUME", "WRITE_VOLUME"]
  }

  depends_on = [databricks_volume.team_landing]
}

# One SQL warehouse per team. Defaults to serverless 2X-Small; override via warehouse block in tfvars.
resource "databricks_sql_endpoint" "team" {
  provider     = databricks.workspace
  for_each     = var.data_product_teams
  name         = "${each.key}-sql-warehouse"
  cluster_size = each.value.warehouse.cluster_size

  min_num_clusters          = each.value.warehouse.min_num_clusters
  max_num_clusters          = each.value.warehouse.max_num_clusters
  auto_stop_mins            = each.value.warehouse.auto_stop_mins
  enable_serverless_compute = each.value.warehouse.serverless
  warehouse_type            = "PRO"

  depends_on = [databricks_metastore_assignment.this]
}

resource "databricks_permissions" "team_warehouse" {
  provider        = databricks.workspace
  for_each        = var.data_product_teams
  sql_endpoint_id = databricks_sql_endpoint.team[each.key].id

  access_control {
    service_principal_name = databricks_service_principal.teams[each.key].application_id
    permission_level       = "CAN_USE"
  }

  access_control {
    group_name       = databricks_group.this["data_platform_admins"].display_name
    permission_level = "CAN_MANAGE"
  }
}
