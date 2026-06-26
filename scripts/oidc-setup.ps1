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

Write-Host "Assigning User Access Administrator on subscription (needed for Terraform role assignments)..."
az role assignment create `
    --assignee-object-id $SP_OID `
    --assignee-principal-type ServicePrincipal `
    --role "User Access Administrator" `
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

Write-Host "Granting Microsoft Graph application permissions (for azuread Terraform provider)..."
# These are application permissions (not delegated) and require admin consent.
$GRAPH_API = "00000003-0000-0000-c000-000000000000"  # Microsoft Graph
$graphPerms = @(
    "62a82d76-70ea-41e2-9197-370581804d09"  # Group.ReadWrite.All  — azuread_group, azuread_group_member
    "741f803b-c850-494e-b5df-cde7c675a1ca"  # User.ReadWrite.All   — azuread_user
    "dbb9058a-0e50-45d7-ae91-66909b5d4664"  # Domain.Read.All      — data.azuread_domains
)
foreach ($perm in $graphPerms) {
    az ad app permission add --id $APP_ID --api $GRAPH_API --api-permissions "$perm=Role" | Out-Null
}
Write-Host "Granting admin consent for Graph permissions (requires Global/App Admin)..."
az ad app permission admin-consent --id $APP_ID

Write-Host "Adding federated credential for environment 'dev'..."
$credJson = @{
    name      = "github-actions-dev"
    issuer    = "https://token.actions.githubusercontent.com"
    subject   = "repo:${GitHubRepo}:environment:dev"
    audiences = @("api://AzureADTokenExchange")
} | ConvertTo-Json -Compress
$tempCred = [System.IO.Path]::GetTempFileName() + ".json"
$credJson | Set-Content $tempCred -Encoding utf8
az ad app federated-credential create --id $APP_ID --parameters "@$tempCred"
Remove-Item $tempCred

Write-Host ""
Write-Host "Done. Add these as GitHub secrets (Settings -> Secrets and variables -> Actions):"
Write-Host "  AZURE_CLIENT_ID      = $APP_ID"
Write-Host "  AZURE_TENANT_ID      = $TENANT_ID"
Write-Host "  AZURE_SUBSCRIPTION_ID = $SUBSCRIPTION_ID"
Write-Host ""
Write-Host "Then add the service principal ($APP_ID) as a Databricks account admin at"
Write-Host "https://accounts.azuredatabricks.net -> User Management -> Service Principals"
