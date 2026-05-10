<#
.SYNOPSIS
    Sets ALL GitHub Environment Variables AND Secrets for the GUSA production environment.
    Idempotent - safe to re-run. Existing values are overwritten.

.REQUIRES
    gh CLI installed and authenticated (gh auth status)
    Must be run as the repo owner (spartnick-hub) or an admin collaborator.

.USAGE
    From PowerShell 7 terminal (Windows Terminal > PowerShell tab):
    & "D:\Dayforce\repos\hcm\gusa-pipeline\setup\Step5-Set-GitHubEnvVars.ps1"

.TO ADD A NEW ENVIRONMENT (e.g. GC, EMEA)
    Copy this file, change $Repo, $Env, and all the values below.
    No changes needed to any workflow or PowerShell script - everything is parameterized.

.WHY PIPE INSTEAD OF --body
    On Windows/PowerShell, 'gh variable set --body "value"' wraps the value in literal
    double-quotes inside GitHub. Piping via stdin ($Value | gh variable set NAME) sends
    the raw string without extra quoting. Same applies to 'gh secret set'.
#>

param(
    [string]$Repo = "spartnick-hub/dayforce-gusa-deployment",
    [string]$Env  = "production"
)

Write-Host "=== Step 5: Set GitHub Environment Variables + Secrets ===" -ForegroundColor Cyan
Write-Host "Repo : $Repo"
Write-Host "Env  : $Env"
Write-Host ""

# Helpers - use stdin pipe (not --body) to avoid gh CLI wrapping values in double-quotes on Windows.

function Set-GHVar($Name, $Value) {
    Write-Host "  [VAR]    $Name" -NoNewline
    $Value | gh variable set $Name --env $Env --repo $Repo 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host " FAILED" -ForegroundColor Red }
    else                      { Write-Host " OK"     -ForegroundColor Green }
}

function Set-GHSecret($Name, $Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        Write-Host "  [SECRET] $Name SKIPPED (empty - set manually in GitHub)" -ForegroundColor Yellow
        return
    }
    Write-Host "  [SECRET] $Name" -NoNewline
    $Value | gh secret set $Name --env $Env --repo $Repo 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host " FAILED" -ForegroundColor Red }
    else                      { Write-Host " OK"     -ForegroundColor Green }
}

# ==============================================================================
# SECTION 1 - ENVIRONMENT VARIABLES (non-sensitive, visible in GitHub UI)
# ==============================================================================
Write-Host ""
Write-Host "--- Variables ---" -ForegroundColor Cyan

# Azure Infrastructure
Set-GHVar "RESOURCE_GROUP"             "rg-gusa-prod-east-us"
Set-GHVar "LOCATION"                   "eastus"
Set-GHVar "VNET_NAME"                  "vnet-gusa-prod-east-us"
Set-GHVar "SUBNET_NAME"                "snet-gusa-prod"
Set-GHVar "VM_SIZE"                    "Standard_D4s_v3"
Set-GHVar "DOMAIN_NAME"                "dayforceusa.local"

# Artifact Staging
# stgusablobeastus = Standard GPv2 - supports blob containers.
# stgusaprodeastus = Premium FileStorage - does NOT support blobs, do not use here.
Set-GHVar "ARTIFACT_STORAGE_ACCOUNT"   "stgusablobeastus"
Set-GHVar "ARTIFACT_CONTAINER"         "deployments"
Set-GHVar "ARTIFACT_ZIP_PREFIX"        "DFCore"

# JFrog Artifactory
Set-GHVar "JFROG_PROD_REPO"            "dfcore-prod-local"
Set-GHVar "JFROG_ARTIFACT_FOLDER"      "Dayforce"
Set-GHVar "JFROG_CLI_PATH"             "C:\HashiCorp\jf.exe"

# Deployment Paths (on the app server / BJE VMs)
Set-GHVar "DEPLOY_PATH"                "F:\Dayforce\Site\prod"
Set-GHVar "BJE_PATH"                   "F:\Dayforce\Bje\prod"
Set-GHVar "BJE_SERVICE"                "wwwprod_BJE"

# IIS App Pools - comma-separated, no spaces.
# NsName prefix (wwwprod) must match siteconfig.yaml.
Set-GHVar "APP_POOLS"                  "wwwprod_Api,wwwprod_MyDayforce,wwwprod_AdminService,wwwprod_OData,wwwprod_ReportingSvc,wwwprod_DataSvc"

# Application / Smoke Test
# APP_DOMAIN is the Host header for smoke test - new VM is hit by direct private IP
# but IIS needs the Host header to route the request to the right site binding.
Set-GHVar "APP_DOMAIN"                 "www.dayforcenextgen.gov"
Set-GHVar "HEALTH_PATH"                "/MyDayforce/Health/Status"
Set-GHVar "VERSION_PATH"               "/MyDayforce/Health/Version"
Set-GHVar "SMOKE_TEST_TIMEOUT_SECONDS" "300"
Set-GHVar "SMOKE_TEST_WARMUP_REQUESTS" "3"

# Database
Set-GHVar "SQL_SERVER"                 "sql-gusa-prod.dayforceusa.local"
Set-GHVar "CONTROL_DB"                 "prodcontrol"
Set-GHVar "DB_SNAPSHOT_PATH"           "F:\Dayforce\DBSnapshots"

# Deployment State Table
# Azure Table Storage tracks which VMs are currently live between deployments.
Set-GHVar "STATE_TABLE_NAME"           "DeploymentState"

# VM Naming
# New VMs are named: {PREFIX}-{yyyyMMddHHmm}, e.g. vm-gusa-appserver-202601151430
Set-GHVar "WEB_VM_NAME_PREFIX"         "vm-gusa-appserver"
Set-GHVar "BJE_VM_NAME_PREFIX"         "vm-gusa-bjeserver"

# Runner / Tools
# RUNNER_LABELS must be a JSON array string - the workflow uses fromJson() on it.
Set-GHVar "RUNNER_LABELS"              '["self-hosted","Windows","gusa-runner"]'
Set-GHVar "STAGING_ROOT"               "C:\DfDeployStaging"
Set-GHVar "SEVENZIP_PATH"              "C:\Program Files\7-Zip\7z.exe"

# HashiCorp Vault - non-secret config
# HC_ prefix distinguishes these from any Azure Key Vault (AKV_) vars added later.
Set-GHVar "HC_VAULT_CLI_PATH"          "C:\HashiCorp\Vault\vault.exe"
Set-GHVar "HC_VAULT_CODESIGN_PATH"     "secret/codesigning/cert"
Set-GHVar "HC_VAULT_CODESIGN_FIELD"    "thumbprint"

# Code Signing DLLs
# Checked in pre-deploy BEFORE any VM is provisioned - fail fast on bad artifact.
Set-GHVar "CODESIGN_DLLS"             "MyDayforce\bin\Dayforce.Common.dll,Api\bin\Dayforce.Api.dll,DataSvc\bin\Dayforce.DataSvc.dll"

# Pod Path - points to prod/{region}/{datacenter}/{pod}/
# Contains siteconfig.yaml (Deployer.exe vars) and iss-metadata.yaml (base image IDs).
# Can be overridden per workflow_dispatch run without changing this default.
Set-GHVar "POD_PATH"                   "prod/us/eastus/wwwprod"

# ==============================================================================
# SECTION 2 - ENVIRONMENT SECRETS (sensitive - values are masked in GitHub logs)
# ==============================================================================
Write-Host ""
Write-Host "--- Secrets ---" -ForegroundColor Cyan

# Azure OIDC - no client secret, uses federated credential.
# GitHub exchanges a short-lived OIDC token - no password stored anywhere.
Set-GHSecret "AZURE_CLIENT_ID"        "b581b048-a3cd-4c31-911c-5351ce7de673"
Set-GHSecret "AZURE_TENANT_ID"        "55f5d6da-59e4-4599-ba22-a97fc476f3aa"
Set-GHSecret "AZURE_SUBSCRIPTION_ID"  "e09a0f00-c31e-48df-a5f3-4bccf78cf898"

# JFrog Artifactory
# Swap JFROG_ACCESS_TOKEN for OIDC when JFrog Enterprise X is available.
Set-GHSecret "JFROG_URL"              "https://freenferal.jfrog.io"
Set-GHSecret "JFROG_ACCESS_TOKEN"     ""

# HashiCorp Vault - AppRole credentials
# HC_ prefix distinguishes from Azure Key Vault secrets (AKV_) if added later.
# AppRole: no long-lived token - Role ID + Secret ID are rotatable independently.
Set-GHSecret "HC_VAULT_ADDR"          "https://vault-gusa-prod-public-vault-8632fb0b.fed357f8.z1.hashicorp.cloud:8200"
Set-GHSecret "HC_VAULT_NAMESPACE"     "admin"
Set-GHSecret "HC_VAULT_ROLE_ID"       "3a4ceeda-3d40-1b93-3a41-05ed5cbc8ab2"
Set-GHSecret "HC_VAULT_SECRET_ID"     "a1c1547c-8ef3-8457-fe63-bfb0b4fc21aa"

# Azure Table Storage - deployment state
# Tracks which VMs are currently live (blue/green) between deployments.
# OIDC service principal has Storage Table Data Contributor on this account.
Set-GHSecret "STATE_STORAGE_ACCOUNT"  "stgusastatetable"

# Azure Load Balancer
Set-GHSecret "LB_NAME"                "lb-gusa-prod-east-us"
Set-GHSecret "LB_BACKEND_POOL"        "be-gusa-appserver"

# VM Base Image fallback
# Primary source is iss-metadata.yaml in the repo (version-controlled, PR-reviewable).
# This secret is only used if iss-metadata.yaml has not been populated yet.
# Set after Azure Compute Gallery + base images are created.
Set-GHSecret "APP_SERVER_BASE_IMAGE"  ""

# gMSA - IIS App Pool identity
# Set after Entra Domain Services finishes provisioning and gMSA is created.
Set-GHSecret "APP_POOL_GMSA"          "dfGusaAppPool$"

# Microsoft Teams incoming webhook URL
# The workflow posts a card to this URL when code signing verification fails.
# How to create: Teams channel → ... → Connectors → Incoming Webhook → copy URL.
# Leave blank here and set manually in GitHub if you prefer not to store it in this script.
Set-GHSecret "TEAMS_WEBHOOK_URL"      ""

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Green
Write-Host ""
Write-Host "Verify at: https://github.com/$Repo/settings/environments"
Write-Host ""
Write-Host "SKIPPED (empty - set manually when ready):"
Write-Host "  APP_SERVER_BASE_IMAGE - after Azure Compute Gallery base images exist"
Write-Host "  TEAMS_WEBHOOK_URL     - Teams channel Incoming Webhook URL"
