<#
.SYNOPSIS
    Creates an app registration and configures Workload Identity Federation for GitHub Actions.
.PARAMETER GitHubRepo
    Your GitHub repository in org/repo format, e.g. "myorg/simple-databricks-deployment"
.EXAMPLE
    .\oidc-setup.ps1 -GitHubRepo "myorg/simple-databricks-deployment"
#>
param(
    [Parameter(Mandatory)]
    [string] $GitHubRepo
)

$STATE_RG = "dbplat-simple-tfstate-rg"
$STATE_SA = "dbplatsimplestate"
$APP_NAME = "dbplat-simple-github-actions"

Write-Host "Fetching subscription and tenant..."
$SUBSCRIPTION_ID = az account show --query id -o tsv
$TENANT_ID       = az account show --query tenantId -o tsv

Write-Host "Creating app registration '$APP_NAME'..."
$APP_ID = az ad app create --display-name $APP_NAME --query appId -o tsv

Write-Host "Creating service principal..."
az ad sp create --id $APP_ID | Out-Null
$SP_OID = az ad sp show --id $APP_ID --query id -o tsv

Write-Host "Assigning Contributor on subscription..."
az role assignment create `
    --assignee-object-id $SP_OID `
    --assignee-principal-type ServicePrincipal `
    --role Contributor `
    --scope "/subscriptions/$SUBSCRIPTION_ID"

Write-Host "Assigning Storage Blob Data Contributor on state storage account..."
$STATE_SA_ID = az storage account show `
    --name $STATE_SA `
    --resource-group $STATE_RG `
    --query id -o tsv

az role assignment create `
    --assignee-object-id $SP_OID `
    --assignee-principal-type ServicePrincipal `
    --role "Storage Blob Data Contributor" `
    --scope $STATE_SA_ID

Write-Host "Adding federated credential for environment 'dev'..."
az ad app federated-credential create --id $APP_ID --parameters (@{
    name      = "github-actions-dev"
    issuer    = "https://token.actions.githubusercontent.com"
    subject   = "repo:${GitHubRepo}:environment:dev"
    audiences = @("api://AzureADTokenExchange")
} | ConvertTo-Json)

Write-Host ""
Write-Host "Done. Add these as GitHub secrets (Settings -> Secrets and variables -> Actions):"
Write-Host "  AZURE_CLIENT_ID      = $APP_ID"
Write-Host "  AZURE_TENANT_ID      = $TENANT_ID"
Write-Host "  AZURE_SUBSCRIPTION_ID = $SUBSCRIPTION_ID"
Write-Host ""
Write-Host "Then add the service principal ($APP_ID) as a Databricks account admin at"
Write-Host "https://accounts.azuredatabricks.net -> User Management -> Service Principals"
