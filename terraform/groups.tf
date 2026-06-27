# ---------------------------------------------------------------------------
# Entra security groups
# ---------------------------------------------------------------------------
# Security groups for the TfL pipeline ABAC governance model. Created here
# so the full group lifecycle (create, rename, destroy) is tracked in state.
#
# Demo users (Norma Redacta, Seymour Cleartext, Stewart Tagger) are created
# in Entra by scripts/bootstrap-groups.ps1 and added to these groups there.
#
# Prerequisite: the GitHub Actions service principal needs the Microsoft Graph
# Group.ReadWrite.All application permission — see the note in providers.tf.

resource "azuread_group" "standard_readers" {
  display_name     = "sg-dbplat-standard-readers"
  mail_enabled     = false
  security_enabled = true
}

resource "azuread_group" "pii_readers" {
  display_name     = "sg-dbplat-pii-readers"
  mail_enabled     = false
  security_enabled = true
}

resource "azuread_group" "data_stewards" {
  display_name     = "sg-dbplat-data-stewards"
  mail_enabled     = false
  security_enabled = true
}

# ---------------------------------------------------------------------------
# Databricks account-level groups
# ---------------------------------------------------------------------------
# Mirrored at the Databricks account level so Unity Catalog grant and column-
# masking policies can reference them. Members sync from the Entra groups
# above via SCIM provisioning.
#
# To enable SCIM: Entra ID -> Enterprise Applications -> Azure Databricks ->
# Provisioning -> enable automatic provisioning, scope to the four groups above.

resource "databricks_group" "standard_readers" {
  provider     = databricks.accounts
  display_name = azuread_group.standard_readers.display_name
}

resource "databricks_group" "pii_readers" {
  provider     = databricks.accounts
  display_name = azuread_group.pii_readers.display_name
}

resource "databricks_group" "data_stewards" {
  provider     = databricks.accounts
  display_name = azuread_group.data_stewards.display_name
}

# ---------------------------------------------------------------------------
# Data platform admins — Entra group + mirrored Databricks account-level group
# ---------------------------------------------------------------------------

resource "azuread_group" "data_platform_admins" {
  display_name     = "sg-dbplat-data-platform-admins"
  mail_enabled     = false
  security_enabled = true
}

data "azuread_user" "platform_admin" {
  user_principal_name = var.owner
}

data "azuread_service_principal" "github_actions" {
  display_name = "dbplat-simple-github-actions"
}

resource "azuread_group_member" "data_platform_admins_julian" {
  group_object_id  = azuread_group.data_platform_admins.object_id
  member_object_id = data.azuread_user.platform_admin.object_id
}

resource "azuread_group_member" "data_platform_admins_github_actions" {
  group_object_id  = azuread_group.data_platform_admins.object_id
  member_object_id = data.azuread_service_principal.github_actions.object_id
}

resource "databricks_group" "data_platform_admins" {
  provider     = databricks.accounts
  display_name = azuread_group.data_platform_admins.display_name
}

resource "databricks_group_role" "data_platform_admins_account_admin" {
  provider = databricks.accounts
  group_id = databricks_group.data_platform_admins.id
  role     = "account_admin"
}

