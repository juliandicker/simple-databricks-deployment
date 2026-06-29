# Import blocks adopt policies already created by setup_abac.py into Terraform state.
# After the first successful apply, Terraform owns these resources.
import {
  id = "CATALOG,silver,mask_name_columns"
  to = databricks_policy_info.abac["silver_mask_name"]
}
import {
  id = "CATALOG,silver,mask_email_columns"
  to = databricks_policy_info.abac["silver_mask_email"]
}
import {
  id = "CATALOG,silver,mask_dob_columns"
  to = databricks_policy_info.abac["silver_mask_dob"]
}
import {
  id = "CATALOG,silver,mask_location_columns"
  to = databricks_policy_info.abac["silver_mask_location"]
}
import {
  id = "CATALOG,gold,mask_name_columns"
  to = databricks_policy_info.abac["gold_mask_name"]
}
import {
  id = "CATALOG,gold,mask_email_columns"
  to = databricks_policy_info.abac["gold_mask_email"]
}
import {
  id = "CATALOG,gold,mask_dob_columns"
  to = databricks_policy_info.abac["gold_mask_dob"]
}
import {
  id = "CATALOG,gold,mask_location_columns"
  to = databricks_policy_info.abac["gold_mask_location"]
}

locals {
  _abac_policies = {
    mask_name = {
      name  = "mask_name_columns"
      tag   = "class.name"
      alias = "name_col"
      fn    = "admin.shared.mask_name"
    }
    mask_email = {
      name  = "mask_email_columns"
      tag   = "class.email_address"
      alias = "email_col"
      fn    = "admin.shared.mask_email"
    }
    mask_dob = {
      name  = "mask_dob_columns"
      tag   = "class.date_of_birth"
      alias = "dob_col"
      fn    = "admin.shared.mask_dob"
    }
    mask_location = {
      name  = "mask_location_columns"
      tag   = "class.location"
      alias = "loc_col"
      fn    = "admin.shared.mask_location"
    }
  }

  # Cartesian product: 4 policies × 2 catalogs = 8 resources
  catalog_policies = merge([
    for catalog in ["silver", "gold"] : {
      for k, p in local._abac_policies :
      "${catalog}_${k}" => merge(p, { catalog = catalog })
    }
  ]...)
}

resource "databricks_policy_info" "abac" {
  provider  = databricks.workspace
  for_each  = local.catalog_policies

  on_securable_type     = "CATALOG"
  on_securable_fullname = each.value.catalog
  name                  = each.value.name
  policy_type           = "POLICY_TYPE_COLUMN_MASK"
  for_securable_type    = "TABLE"
  to_principals         = ["account users"]
  except_principals     = ["sg-dbplat-pii-readers", "sg-dbplat-data-stewards"]

  match_columns = [
    {
      condition = "has_tag('${each.value.tag}')"
      alias     = each.value.alias
    }
  ]

  column_mask = {
    function_name = each.value.fn
    on_column     = each.value.alias
  }

  depends_on = [databricks_catalog.this]
}
