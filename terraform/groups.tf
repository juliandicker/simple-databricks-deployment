# ---------------------------------------------------------------------------
# Entra security groups
# ---------------------------------------------------------------------------

resource "azuread_group" "this" {
  for_each         = var.groups
  display_name     = each.value.display_name
  mail_enabled     = false
  security_enabled = true
}

# ---------------------------------------------------------------------------
# Databricks account-level mirror groups
# ---------------------------------------------------------------------------
# AIM syncs members from Entra. Service principals that need immediate
# access are also added directly via databricks_group_member below.

resource "databricks_group" "this" {
  provider     = databricks.accounts
  for_each     = var.groups
  display_name = azuread_group.this[each.key].display_name
}

# ---------------------------------------------------------------------------
# Group roles and membership locals
# ---------------------------------------------------------------------------

locals {
  group_roles = flatten([
    for group_key, group in var.groups : [
      for role in group.databricks_roles : {
        key       = "${group_key}:${role}"
        group_key = group_key
        role      = role
      }
    ]
  ])

  # Merge var.owner into any group with inject_owner = true so the platform
  # admin UPN stays out of version control (passed as TF_VAR_owner in CI).
  effective_group_members = {
    for group_key, group in var.groups : group_key => {
      user_upns = concat(
        try(var.group_members[group_key].user_upns, []),
        group.inject_owner ? [var.owner] : []
      )
      service_principals = try(var.group_members[group_key].service_principals, [])
    }
  }

  all_user_upns = toset(flatten([
    for _, m in local.effective_group_members : m.user_upns
  ]))

  group_user_memberships = flatten([
    for group_key, m in local.effective_group_members : [
      for upn in m.user_upns : {
        key       = "${group_key}:${upn}"
        group_key = group_key
        upn       = upn
      }
    ]
  ])

  all_sp_names = toset(flatten([
    for _, m in local.effective_group_members : m.service_principals
  ]))

  group_sp_memberships = flatten([
    for group_key, m in local.effective_group_members : [
      for sp_name in m.service_principals : {
        key       = "${group_key}:${sp_name}"
        group_key = group_key
        sp_name   = sp_name
      }
    ]
  ])
}

# ---------------------------------------------------------------------------
# Databricks group roles (e.g. account_admin)
# ---------------------------------------------------------------------------

resource "databricks_group_role" "this" {
  provider = databricks.accounts
  for_each = { for gr in local.group_roles : gr.key => gr }
  group_id = databricks_group.this[each.value.group_key].id
  role     = each.value.role
}

# ---------------------------------------------------------------------------
# Entra memberships — existing users (looked up by UPN)
# ---------------------------------------------------------------------------

data "azuread_user" "members" {
  for_each            = local.all_user_upns
  user_principal_name = each.value
}

resource "azuread_group_member" "users" {
  for_each         = { for item in local.group_user_memberships : item.key => item }
  group_object_id  = azuread_group.this[each.value.group_key].object_id
  member_object_id = data.azuread_user.members[each.value.upn].object_id
}

# ---------------------------------------------------------------------------
# Entra + Databricks memberships — service principals
# ---------------------------------------------------------------------------
# Added to both Entra (for AIM) and directly to the Databricks group so
# the SP has group privileges immediately without waiting for AIM to sync.

data "azuread_service_principal" "members" {
  for_each     = local.all_sp_names
  display_name = each.value
}

resource "azuread_group_member" "service_principals" {
  for_each         = { for item in local.group_sp_memberships : item.key => item }
  group_object_id  = azuread_group.this[each.value.group_key].object_id
  member_object_id = data.azuread_service_principal.members[each.value.sp_name].object_id
}

data "databricks_service_principal" "members" {
  provider       = databricks.accounts
  for_each       = local.all_sp_names
  application_id = data.azuread_service_principal.members[each.key].client_id
}

resource "databricks_group_member" "service_principals_db" {
  provider  = databricks.accounts
  for_each  = { for item in local.group_sp_memberships : item.key => item }
  group_id  = databricks_group.this[each.value.group_key].id
  member_id = data.databricks_service_principal.members[each.value.sp_name].id
}
