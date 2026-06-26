# Databricks account-level groups for the TfL pipeline ABAC governance model.
# These are created at account level so they apply across workspaces and are
# available to Unity Catalog grant and column-masking policies.
#
# Entra group members are synced into these groups via SCIM provisioning.
# To set up SCIM: Entra ID → Enterprise Applications → Azure Databricks →
# Provisioning → enable automatic provisioning and scope to these groups.
#
# Demo users (Norma Redacta, Seymour Cleartext, Stewart Tagger) are created
# in Entra by scripts/bootstrap-groups.ps1 and sync here once SCIM is active.

resource "databricks_group" "standard_readers" {
  provider     = databricks.accounts
  display_name = "sg-dbplat-standard-readers"
}

resource "databricks_group" "pii_readers" {
  provider     = databricks.accounts
  display_name = "sg-dbplat-pii-readers"
}

resource "databricks_group" "data_stewards" {
  provider     = databricks.accounts
  display_name = "sg-dbplat-data-stewards"
}
