# Demo users for testing masked vs unmasked PII access.
# One user per governance tier — names chosen to reflect their access level.
# Passwords are set once at creation; Terraform does not rotate them.

data "azuread_domains" "default" {
  only_default = true
}

locals {
  upn_domain = data.azuread_domains.default.domains[0].domain_name
}

resource "azuread_user" "norma_redacta" {
  display_name          = "Norma Redacta"
  user_principal_name   = "norma.redacta@${local.upn_domain}"
  mail_nickname         = "norma.redacta"
  password              = var.demo_user_password
  force_password_change = false
}

resource "azuread_user" "seymour_cleartext" {
  display_name          = "Seymour Cleartext"
  user_principal_name   = "seymour.cleartext@${local.upn_domain}"
  mail_nickname         = "seymour.cleartext"
  password              = var.demo_user_password
  force_password_change = false
}

resource "azuread_user" "stewart_tagger" {
  display_name          = "Stewart Tagger"
  user_principal_name   = "stewart.tagger@${local.upn_domain}"
  mail_nickname         = "stewart.tagger"
  password              = var.demo_user_password
  force_password_change = false
}

resource "azuread_group_member" "norma_standard_readers" {
  group_object_id  = azuread_group.standard_readers.object_id
  member_object_id = azuread_user.norma_redacta.object_id
}

resource "azuread_group_member" "seymour_pii_readers" {
  group_object_id  = azuread_group.pii_readers.object_id
  member_object_id = azuread_user.seymour_cleartext.object_id
}

resource "azuread_group_member" "stewart_data_stewards" {
  group_object_id  = azuread_group.data_stewards.object_id
  member_object_id = azuread_user.stewart_tagger.object_id
}
