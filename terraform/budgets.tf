# ---------------------------------------------------------------------------
# Databricks Serverless Budget Policies, ACL Rule Sets, and Budget Alerts
#
# Budget policies tag serverless compute activity so team costs appear in
# system.billing.usage.custom_tags — enabling per-team attribution and
# chargeback. They do not cap spend.
#
# Budget alerts fire when monthly list-price USD spend exceeds the threshold.
#
# All resources use the accounts provider (databricks.accounts).
# ---------------------------------------------------------------------------

locals {
  teams_with_budget = {
    for k, v in var.data_product_teams : k => v
    if v.budget.enabled && coalesce(v.budget.alert_email, var.owner, "") != ""
  }

  # Temporary kill switch: the account is stuck returning "Duplicate policy
  # name found" for team-data_platform_admins/team-travel/platform even
  # though databricks_budget_policy.list() shows zero policies — suspected
  # orphaned entries from a prior destroy/apply cycle not visible via the
  # list API. Sourced from repeated apply failures on 2026-09-25; re-enable
  # once Databricks support confirms the account-side state is clean.
  budget_policies_enabled = false
}

# ---------------------------------------------------------------------------
# Per-team budget policies
# One policy per entry in var.data_product_teams (including data_platform_admins).
# Tags serverless compute with team=<key> and cost_centre=<var.cost_centre>.
# ---------------------------------------------------------------------------

resource "databricks_budget_policy" "team" {
  provider  = databricks.accounts
  for_each  = local.budget_policies_enabled ? var.data_product_teams : {}

  policy_name           = "team-${each.key}"
  binding_workspace_ids = [azurerm_databricks_workspace.this.workspace_id]

  custom_tags = [
    { key = "team", value = each.key },
    { key = "cost_centre", value = coalesce(each.value.cost_centre, var.cost_centre) }
  ]
}

# ---------------------------------------------------------------------------
# Platform budget policy
# Separate from the per-team loop: tags serverless compute run by members
# of the data_platform_admins group directly (group identity, not a team SP).
# ---------------------------------------------------------------------------

resource "databricks_budget_policy" "platform" {
  provider = databricks.accounts
  count    = local.budget_policies_enabled ? 1 : 0

  policy_name           = "platform"
  binding_workspace_ids = [azurerm_databricks_workspace.this.workspace_id]

  custom_tags = [
    { key = "team", value = "platform" },
    { key = "cost_centre", value = var.cost_centre }
  ]
}

# ---------------------------------------------------------------------------
# ACL rule sets for per-team budget policies
# AUTHORITATIVE: overwrites all existing permissions on the target policy.
# Both roles must appear in the same resource block to avoid overwriting.
# Since each team SP is assigned to exactly one policy, Databricks auto-applies
# it to all new serverless resources — no manual selection required.
# ---------------------------------------------------------------------------

resource "databricks_access_control_rule_set" "team_budget_policy" {
  provider = databricks.accounts
  for_each = local.budget_policies_enabled ? var.data_product_teams : {}

  name = "accounts/${var.databricks_account_id}/budgetPolicies/${databricks_budget_policy.team[each.key].policy_id}/ruleSets/default"

  grant_rules {
    role       = "roles/budgetPolicy.user"
    principals = [databricks_service_principal.teams[each.key].acl_principal_id]
  }

  grant_rules {
    role       = "roles/budgetPolicy.manager"
    principals = [databricks_group.this["data_platform_admins"].acl_principal_id]
  }
}

# ---------------------------------------------------------------------------
# ACL rule set for the platform budget policy
# data_platform_admins group holds both user and manager roles.
# ---------------------------------------------------------------------------

resource "databricks_access_control_rule_set" "platform_budget_policy" {
  provider = databricks.accounts
  count    = local.budget_policies_enabled ? 1 : 0

  name = "accounts/${var.databricks_account_id}/budgetPolicies/${databricks_budget_policy.platform[0].policy_id}/ruleSets/default"

  grant_rules {
    role       = "roles/budgetPolicy.user"
    principals = [databricks_group.this["data_platform_admins"].acl_principal_id]
  }

  grant_rules {
    role       = "roles/budgetPolicy.manager"
    principals = [databricks_group.this["data_platform_admins"].acl_principal_id]
  }
}

# ---------------------------------------------------------------------------
# Per-team budget alerts (optional)
# Created only when budget.enabled = true and alert_email is set in tfvars.
# Filters on the team tag so only spend attributed to that team contributes.
# ---------------------------------------------------------------------------

resource "databricks_budget" "team" {
  provider = databricks.accounts
  for_each = local.teams_with_budget

  display_name = "team-${each.key}-monthly"

  alert_configurations {
    time_period        = "MONTH"
    trigger_type       = "CUMULATIVE_SPENDING_EXCEEDED"
    quantity_type      = "LIST_PRICE_DOLLARS_USD"
    quantity_threshold = tostring(each.value.budget.alert_threshold_usd)

    action_configurations {
      action_type = "EMAIL_NOTIFICATION"
      target      = coalesce(each.value.budget.alert_email, var.owner)
    }
  }

  filter {
    workspace_id {
      operator = "IN"
      values   = [azurerm_databricks_workspace.this.workspace_id]
    }
    tags {
      key = "team"
      value {
        operator = "IN"
        values   = [each.key]
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Platform-wide budget alert (optional singleton)
# Covers all spend on the workspace; not filtered by team tag.
# Enabled via var.platform_budget in tfvars.
# ---------------------------------------------------------------------------

resource "databricks_budget" "platform" {
  provider = databricks.accounts
  count    = var.platform_budget.enabled && coalesce(var.platform_budget.alert_email, var.owner, "") != "" ? 1 : 0

  display_name = "platform-monthly"

  alert_configurations {
    time_period        = "MONTH"
    trigger_type       = "CUMULATIVE_SPENDING_EXCEEDED"
    quantity_type      = "LIST_PRICE_DOLLARS_USD"
    quantity_threshold = tostring(var.platform_budget.alert_threshold_usd)

    action_configurations {
      action_type = "EMAIL_NOTIFICATION"
      target      = coalesce(var.platform_budget.alert_email, var.owner)
    }
  }

  filter {
    workspace_id {
      operator = "IN"
      values   = [azurerm_databricks_workspace.this.workspace_id]
    }
  }
}
