<#
.SYNOPSIS
    Creates the Terraform remote state backend (run once before terraform init).
.DESCRIPTION
    Creates a resource group, storage account, and blob container for Terraform state.
    If you change STATE_SA, update storage_account_name in terraform/backend.tf to match.
#>

$LOCATION       = "uksouth"
$STATE_RG       = "dbplat-simple-tfstate-rg"
$STATE_SA       = "dbplatsimplestate"   # must be globally unique — change if taken
$STATE_CONTAINER = "tfstate"

Write-Host "Creating resource group '$STATE_RG'..."
az group create --name $STATE_RG --location $LOCATION

Write-Host "Creating storage account '$STATE_SA'..."
az storage account create `
    --name $STATE_SA `
    --resource-group $STATE_RG `
    --location $LOCATION `
    --sku Standard_LRS `
    --kind StorageV2 `
    --https-only true `
    --min-tls-version TLS1_2

Write-Host "Creating blob container '$STATE_CONTAINER'..."
az storage container create `
    --name $STATE_CONTAINER `
    --account-name $STATE_SA `
    --auth-mode login

Write-Host "Bootstrap complete. Run 'terraform init' from the terraform/ directory."
