# Demo users for testing masked vs unmasked PII access.
# Passwords are set once at creation; Terraform does not rotate them.

data "azuread_domains" "default" {
  only_default = true
}

locals {
  upn_domain = data.azuread_domains.default.domains[0].domain_name
}

resource "azuread_user" "demo" {
  for_each              = var.demo_users
  display_name          = each.value.display_name
  user_principal_name   = "${each.value.mail_nickname}@${local.upn_domain}"
  mail_nickname         = each.value.mail_nickname
  password              = var.demo_user_password
  force_password_change = false
}

resource "azuread_group_member" "demo_users" {
  for_each         = var.demo_users
  group_object_id  = azuread_group.this[each.value.group_key].object_id
  member_object_id = azuread_user.demo[each.key].object_id
}
