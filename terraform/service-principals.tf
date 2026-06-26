# ---------------------------------------------------------------------------
# Pipeline service principal
# Owns and executes all TfL pipeline jobs and Declarative Pipelines.
# No client secret is needed: Databricks manages OAuth tokens internally
# for the run_as execution model. A secret would only be required if CI/CD
# were deploying the bundle *as* the SP rather than *as* the human admin.
# ---------------------------------------------------------------------------

resource "azuread_application" "pipeline" {
  display_name = "sp-tfl-pipeline"
}

resource "azuread_service_principal" "pipeline" {
  client_id = azuread_application.pipeline.client_id
}

# Register in the Databricks workspace. In a UC-enabled workspace this also
# makes the SP visible at account level, so Unity Catalog grants work.
resource "databricks_service_principal" "pipeline" {
  provider       = databricks.workspace
  application_id = azuread_service_principal.pipeline.client_id
  display_name   = azuread_application.pipeline.display_name

  depends_on = [databricks_metastore_assignment.this]
}
