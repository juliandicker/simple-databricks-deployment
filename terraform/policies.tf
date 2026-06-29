# ABAC policies are created and managed by the governance-setup job in the
# tfl-disruption-data-pipeline repo (setup_abac.py). The pipeline SP is
# account admin and has the privileges needed to create functions and policies.
removed {
  from = databricks_policy_info.abac

  lifecycle {
    destroy = false
  }
}
