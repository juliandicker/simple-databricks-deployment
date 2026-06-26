# ---------------------------------------------------------------------------
# Pipeline service principal
# The Azure AD app registration is created out-of-band once (see below) and
# its client ID passed in as var.pipeline_sp_client_id. Terraform then owns
# the federated credential and the Databricks SP registration, so tear-down
# and rebuild require no manual steps.
#
# One-time bootstrap (run locally when first setting up the demo):
#   $appId = az ad app create --display-name "sp-tfl-pipeline" --query appId -o tsv
#   az ad sp create --id $appId
#   # Add $appId as GitHub secret PIPELINE_SP_CLIENT_ID in both repos
# ---------------------------------------------------------------------------

# Read the existing app registration so we can attach a federated credential to it.
# Requires Application.ReadWrite.All on the CI SP (already consented).
data "azuread_application" "pipeline" {
  client_id = var.pipeline_sp_client_id
}

# Federated identity credential — lets the pipeline repo's GitHub Actions workflow
# authenticate as sp-tfl-pipeline via OIDC with no stored secret.
# Recreated automatically on every terraform apply.
resource "azuread_application_federated_identity_credential" "pipeline_github" {
  application_id = data.azuread_application.pipeline.id
  display_name   = "github-actions-tfl-pipeline-dev"
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:juliandicker/tfl-disruption-data-pipeline:environment:dev"
  audiences      = ["api://AzureADTokenExchange"]
}

# Register in the Databricks workspace. In a UC-enabled workspace this also
# makes the SP visible at account level, so Unity Catalog grants work.
resource "databricks_service_principal" "pipeline" {
  provider       = databricks.workspace
  application_id = var.pipeline_sp_client_id
  display_name   = "sp-tfl-pipeline"

  depends_on = [databricks_metastore_assignment.this]
}
