<#
.SYNOPSIS
    Runs the SAR app locally against the real deployed workspace.
.DESCRIPTION
    Wraps `databricks apps run-local` per docs/sar-app.md's "Local development"
    section:
      - resolves the workspace's platform SQL warehouse ID from Terraform
        outputs, rather than hardcoding it, so this script keeps working
        across destroy/apply cycles (each cycle gets a new workspace/warehouse)
      - starts that warehouse if it's stopped - a stopped warehouse's cold
        start isn't reliably handled by the SQL connector's own request
        timeout, so searching while it's still starting fails with a bare
        `databricks.sql.exc.RequestError`
      - fetches a fresh OAuth token (tokens last about an hour; a
        long-running `run-local` process keeps using the token it launched
        with, so restart via this script rather than reusing an old window)
      - launches the app

    Requires a one-time `databricks auth login --host <workspace-host> -p <Profile>`
    before first use, and again whenever the cached token is invalid (check
    with `databricks auth profiles`).
.PARAMETER Profile
    The ~/.databrickscfg profile name for the deployed workspace.
.PARAMETER InstallDeps
    Also run `pip install -r requirements.txt` first (skipped by default -
    only needed once, or after requirements.txt changes).
#>

param(
    [string]$Profile = "adb-7405619162316939",
    [switch]$InstallDeps
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$terraformDir = Join-Path $repoRoot "terraform"
$appDir = Join-Path $repoRoot "apps\sar_app"

Write-Host "Checking auth profile '$Profile'..."
$profiles = (databricks auth profiles -o json | ConvertFrom-Json).profiles
$current = $profiles | Where-Object { $_.name -eq $Profile }
if (-not $current -or -not $current.valid) {
    Write-Error "Profile '$Profile' is missing or its cached token is invalid. Run:`n  databricks auth login --host <workspace-host> -p $Profile`nthen re-run this script."
    exit 1
}

if ($InstallDeps) {
    Write-Host "Installing Python dependencies..."
    Push-Location $appDir
    try {
        pip install -r requirements.txt
    } finally {
        Pop-Location
    }
}

Write-Host "Reading the platform SQL warehouse ID from Terraform outputs..."
Push-Location $terraformDir
try {
    $warehouseId = (terraform output -json team_warehouse_ids | ConvertFrom-Json).data_platform_admins
} finally {
    Pop-Location
}
if (-not $warehouseId) {
    Write-Error "Could not read team_warehouse_ids.data_platform_admins from Terraform outputs. Run 'terraform apply' first."
    exit 1
}

Write-Host "Ensuring SQL warehouse '$warehouseId' is running..."
$warehouse = databricks warehouses get $warehouseId -p $Profile -o json | ConvertFrom-Json
if ($warehouse.state -ne "RUNNING") {
    Write-Host "Warehouse is '$($warehouse.state)' - starting it (this blocks until ready, can take a minute or two)..."
    databricks warehouses start $warehouseId -p $Profile | Out-Null
}

Write-Host "Fetching a fresh access token..."
$token = (databricks auth token -p $Profile | ConvertFrom-Json).access_token

Write-Host "Launching the app - open the printed proxy URL (not the raw Streamlit port) once it's ready..."
Push-Location $appDir
try {
    databricks apps run-local -p $Profile `
        --env DATABRICKS_WAREHOUSE_ID=$warehouseId `
        --env DATABRICKS_TOKEN=$token
} finally {
    Pop-Location
}
