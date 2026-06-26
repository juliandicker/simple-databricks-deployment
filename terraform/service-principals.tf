# ---------------------------------------------------------------------------
# Pipeline service principal — fully managed by Terraform.
# Requires Application.ReadWrite.All on the CI SP (consented via portal).
# ---------------------------------------------------------------------------

resource "azuread_application" "pipeline" {
  display_name = "sp-tfl-pipeline"
}

resource "azuread_service_principal" "pipeline" {
  client_id = azuread_application.pipeline.client_id
}

# Federated identity credential — lets the pipeline repo's GitHub Actions
# authenticate as sp-tfl-pipeline via OIDC with no stored secret.
# Recreated automatically on every terraform apply.
resource "azuread_application_federated_identity_credential" "pipeline_github" {
  application_id = azuread_application.pipeline.id
  display_name   = "github-actions-tfl-pipeline-dev"
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:juliandicker/tfl-disruption-data-pipeline:environment:dev"
  audiences      = ["api://AzureADTokenExchange"]
}

# Register in the Databricks workspace. In a UC-enabled workspace this also
# makes the SP visible at account level, so Unity Catalog grants work.
resource "databricks_service_principal" "pipeline" {
  provider       = databricks.workspace
  application_id = azuread_service_principal.pipeline.client_id
  display_name   = azuread_application.pipeline.display_name

  depends_on = [databricks_metastore_assignment.this]
}
