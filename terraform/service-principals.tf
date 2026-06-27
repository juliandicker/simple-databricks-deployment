# ---------------------------------------------------------------------------
# Service principals — fully managed by Terraform.
# Requires Application.ReadWrite.All on the CI SP (consented via portal).
# ---------------------------------------------------------------------------

resource "azuread_application" "this" {
  for_each     = var.service_principals
  display_name = each.value.display_name
}

resource "azuread_service_principal" "this" {
  for_each  = var.service_principals
  client_id = azuread_application.this[each.key].client_id
}

locals {
  sp_github_creds = {
    for key, sp in var.service_principals : key => sp
    if sp.github_repo != null
  }
}

# Federated identity credential — lets each service principal's GitHub Actions
# workflow authenticate via OIDC with no stored secret.
resource "azuread_application_federated_identity_credential" "this" {
  for_each       = local.sp_github_creds
  application_id = azuread_application.this[each.key].id
  display_name   = "github-actions-${each.key}-${each.value.github_environment}"
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${each.value.github_repo}:environment:${each.value.github_environment}"
  audiences      = ["api://AzureADTokenExchange"]
}

# Register in the Databricks workspace. In a UC-enabled workspace this also
# makes the SP visible at account level, so Unity Catalog grants work.
resource "databricks_service_principal" "this" {
  provider       = databricks.workspace
  for_each       = var.service_principals
  application_id = azuread_service_principal.this[each.key].client_id
  display_name   = azuread_application.this[each.key].display_name

  depends_on = [databricks_metastore_assignment.this]
}

# ---------------------------------------------------------------------------
# State migration — rename from singleton resources to for_each instances
# ---------------------------------------------------------------------------

moved {
  from = azuread_application.pipeline
  to   = azuread_application.this["pipeline"]
}

moved {
  from = azuread_service_principal.pipeline
  to   = azuread_service_principal.this["pipeline"]
}

moved {
  from = databricks_service_principal.pipeline
  to   = databricks_service_principal.this["pipeline"]
}
