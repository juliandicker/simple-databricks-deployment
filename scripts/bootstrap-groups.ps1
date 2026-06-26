<#
.SYNOPSIS
    Creates three demo Entra users and adds them to the pipeline governance groups.

.DESCRIPTION
    The groups themselves are provisioned by Terraform (groups.tf) — run
    'terraform apply' before this script. This script only creates the
    demo user accounts and assigns each to its group.

    Idempotent — safe to run multiple times.

    Users created:
      Norma Redacta     → sg-dbplat-standard-readers  (PII masked)
      Seymour Cleartext → sg-dbplat-pii-readers        (PII visible)
      Stewart Tagger    → sg-dbplat-data-stewards       (full governance access)

.PARAMETER Password
    Initial password for all three demo users. Must satisfy your tenant's
    password complexity policy.

.PARAMETER TenantDomain
    UPN suffix for new users, e.g. contoso.onmicrosoft.com or a verified custom domain.
    Defaults to the tenant's default domain (read from az account show).

.EXAMPLE
    .\scripts\bootstrap-groups.ps1 -Password "Dbx@Demo2025!"
#>
param(
    [Parameter(Mandatory)]
    [string] $Password,

    [string] $TenantDomain = ""
)

if (-not $TenantDomain) {
    Write-Host "Detecting tenant domain..."
    $TenantDomain = az account show --query tenantDefaultDomain -o tsv
}
Write-Host "Tenant domain: $TenantDomain"

# ---------------------------------------------------------------------------
# Users — names chosen to reflect their access tier
#
#   Norma Redacta     → standard-readers  (her data is always redacted)
#   Seymour Cleartext → pii-readers       (sees more, in cleartext)
#   Stewart Tagger    → data-stewards     (stewards the tags)
# ---------------------------------------------------------------------------

$users = @(
    [PSCustomObject]@{ DisplayName = "Norma Redacta";    Nickname = "norma.redacta";    Group = "sg-dbplat-standard-readers" }
    [PSCustomObject]@{ DisplayName = "Seymour Cleartext"; Nickname = "seymour.cleartext"; Group = "sg-dbplat-pii-readers" }
    [PSCustomObject]@{ DisplayName = "Stewart Tagger";   Nickname = "stewart.tagger";   Group = "sg-dbplat-data-stewards" }
)

$summary = @()

foreach ($u in $users) {
    $upn = "$($u.Nickname)@$TenantDomain"

    # User
    $existing = az ad user show --id $upn 2>$null | ConvertFrom-Json
    if ($existing) {
        Write-Host "User '$upn' already exists — skipping creation." -ForegroundColor Yellow
        $userId = $existing.id
    } else {
        Write-Host "Creating user '$($u.DisplayName)' ($upn)..."
        $user = az ad user create `
            --display-name        $u.DisplayName `
            --user-principal-name $upn `
            --password            $Password `
            --force-change-password-next-sign-in false | ConvertFrom-Json
        $userId = $user.id
        Write-Host "  Created ($userId)" -ForegroundColor Green
    }

    # Group membership — group must already exist (created by terraform apply)
    $group    = az ad group show --group $u.Group 2>$null | ConvertFrom-Json
    if (-not $group) {
        Write-Error "Group '$($u.Group)' not found. Run 'terraform apply' in the terraform/ directory first."
        exit 1
    }
    $isMember = az ad group member check --group $group.id --member-id $userId --query value -o tsv
    if ($isMember -eq "true") {
        Write-Host "  Already a member of '$($u.Group)'" -ForegroundColor Yellow
    } else {
        Write-Host "  Adding to '$($u.Group)'..."
        az ad group member add --group $group.id --member-id $userId | Out-Null
        Write-Host "  Added" -ForegroundColor Green
    }

    $summary += [PSCustomObject]@{
        Name     = $u.DisplayName
        UPN      = $upn
        Group    = $u.Group
        Password = $Password
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "Demo users ready:" -ForegroundColor Cyan
$summary | Format-Table -AutoSize

Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Enable SCIM in Entra to sync group members into Databricks automatically:"
Write-Host "     Entra ID -> Enterprise Applications -> Azure Databricks -> Provisioning"
Write-Host "  2. Run the governance-setup DAB job to apply catalog grants and column masks."
Write-Host "  3. Log in as each user to verify masked vs unmasked PII access."
