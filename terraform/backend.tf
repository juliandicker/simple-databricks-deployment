terraform {
  backend "azurerm" {
    # These values must match the resources created by the bootstrap script in README.md.
    # They cannot be Terraform variables — edit the values here directly.
    resource_group_name  = "dbplat-simple-tfstate-rg"
    storage_account_name = "dbplatsimplestate" # must be globally unique; change if taken
    container_name       = "tfstate"
    key                  = "simple-databricks.tfstate"
    use_oidc             = true
  }
}
