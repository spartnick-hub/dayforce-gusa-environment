<#
.SYNOPSIS
    Creates the GitHub App for VMSS runner registration and stores its credentials in HCP Vault.

.WHY GITHUB APP INSTEAD OF PAT
    A PAT is tied to a personal account and expires. A GitHub App:
    - Is independent of any user account
    - Generates short-lived installation tokens (1 hour) on demand - no long-lived secret
    - Private key is stored in HCP Vault (not in VMSS config in plain text)
    - Can be rotated without touching the VMSS

.WHAT THIS SCRIPT DOES
    Part 1 (manual - you do in GitHub UI):
        Create the GitHub App and download the private key PEM file.
        Instructions printed by this script.

    Part 2 (automated - run this script):
        - Logs into HCP Vault using existing AppRole credentials
        - Stores the App ID and private key PEM at secret/github/app in Vault
        - Updates the Vault policy so the runner AppRole can read that path
        - Installs the GitHub App on the target repo

.USAGE
    1. Follow the instructions printed under "STEP 1 - Create GitHub App in GitHub UI"
    2. Download the private key PEM file when prompted by GitHub
    3. Run: & "D:\Dayforce\repos\hcm\gusa-pipeline\setup\Step6a-Create-GitHubApp.ps1"

.INPUTS
    $AppId       - The numeric App ID shown on the GitHub App settings page
    $PrivateKeyPath - Path to the downloaded .pem file
    $VaultAddr, $VaultRoleId, $VaultSecretId - HCP Vault AppRole credentials (already configured)
#>

param(
    [string]$GHRepo         = "spartnick-hub/dayforce-gusa-deployment",
    [string]$AppName        = "gusa-runner-registration",

    # HCP Vault - same AppRole used by the CD pipeline
    # Uses REST API directly - no vault CLI required on local machine
    [string]$VaultAddr      = "https://vault-gusa-prod-public-vault-8632fb0b.fed357f8.z1.hashicorp.cloud:8200",
    [string]$VaultNamespace = "admin",
    [string]$VaultRoleId    = "3a4ceeda-3d40-1b93-3a41-05ed5cbc8ab2",

    # GitHub App - fill in after creating in UI
    [string]$AppId          = "",
    [string]$PrivateKeyPath = ""   # e.g. C:\Users\freen\Downloads\gusa-runner-registration.2026-05-07.private-key.pem
)

$ErrorActionPreference = "Stop"

Write-Host "=== Step 6a: GitHub App for VMSS Runner Registration ===" -ForegroundColor Cyan
Write-Host ""

# ==============================================================================
# STEP 1 - Create GitHub App in GitHub UI (manual)
# ==============================================================================
Write-Host "------------------------------------------------------------" -ForegroundColor Yellow
Write-Host "STEP 1 - Create the GitHub App (do this first in the browser)" -ForegroundColor Yellow
Write-Host "------------------------------------------------------------"
Write-Host ""
Write-Host "1. Go to: https://github.com/settings/apps/new"
Write-Host "   (or https://github.com/organizations/YOUR_ORG/settings/apps/new for org apps)"
Write-Host ""
Write-Host "2. Fill in:"
Write-Host "   - GitHub App name : $AppName"
Write-Host "   - Homepage URL    : https://github.com/$GHRepo  (any URL works)"
Write-Host "   - Uncheck 'Active' under Webhook (no webhook needed)"
Write-Host ""
Write-Host "3. Permissions - Repository permissions:"
Write-Host "   - Administration : Read and Write  (required for runner registration)"
Write-Host "   - Actions        : Read and Write  (required to manage runners)"
Write-Host "   - Metadata       : Read (required, auto-set)"
Write-Host ""
Write-Host "4. Where can this GitHub App be installed?"
Write-Host "   - Select 'Only on this account'"
Write-Host ""
Write-Host "5. Click 'Create GitHub App'"
Write-Host "6. On the App settings page, note the 'App ID' (a number)"
Write-Host "7. Scroll down and click 'Generate a private key' - saves a .pem file"
Write-Host "8. Click 'Install App' (left sidebar) -> Install on $GHRepo"
Write-Host ""
Write-Host "Then come back here and run this script with -AppId and -PrivateKeyPath" -ForegroundColor Cyan
Write-Host ""

if ([string]::IsNullOrWhiteSpace($AppId)) {
    $AppId = Read-Host "Enter the App ID (number from the GitHub App settings page)"
}
if ([string]::IsNullOrWhiteSpace($PrivateKeyPath)) {
    $PrivateKeyPath = Read-Host "Enter the full path to the downloaded .pem file"
}

if (-not (Test-Path $PrivateKeyPath)) { throw "Private key file not found: $PrivateKeyPath" }
$PrivateKeyPem = Get-Content $PrivateKeyPath -Raw

Write-Host ""
Write-Host "App ID       : $AppId"
Write-Host "Private key  : $PrivateKeyPath ($([Math]::Round((Get-Item $PrivateKeyPath).Length / 1KB, 1)) KB)"

# ==============================================================================
# STEP 2 - Store GitHub App credentials in HCP Vault
# ==============================================================================
Write-Host ""
Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "STEP 2 - Storing credentials in HCP Vault"
Write-Host "------------------------------------------------------------"

# Admin token is needed to write secrets and update policies.
# Generate one from: HCP Vault portal -> "New admin token" -> "Generate token"
# It expires after ~6 hours - this is a one-time setup operation.
Write-Host "Admin token needed to write secrets and update policies."
Write-Host "Get one from: HCP Vault portal -> 'New admin token' -> 'Generate token'"
$adminToken = Read-Host "HCP Vault admin token"
if ([string]::IsNullOrWhiteSpace($adminToken)) { throw "Admin token is required." }

# All Vault operations use Invoke-RestMethod (REST API) - no vault CLI needed locally.
$baseUrl = "$VaultAddr/v1"
$headers = @{
    "X-Vault-Namespace" = $VaultNamespace
    "X-Vault-Token"     = $adminToken
}

# ==============================================================================
# STEP 3 - Update Vault policy FIRST so AppRole can read secret/github/app
# Policy update must happen before the AppRole tries to read the new secret path.
# ==============================================================================
Write-Host ""
Write-Host "Updating Vault policy to allow AppRole to read secret/github/app ..."

$policyRules = 'path "secret/data/codesigning/cert" { capabilities = ["read"] } path "secret/data/github/app" { capabilities = ["read"] }'
$policyBody  = @{ policy = $policyRules } | ConvertTo-Json
Invoke-RestMethod -Uri "$baseUrl/sys/policies/acl/app-read-write" -Method PUT -Body $policyBody -ContentType "application/json" -Headers $headers | Out-Null
Write-Host "Vault policy updated." -ForegroundColor Green

# Store app_id and private_key as a single KV v2 secret.
# The private key PEM newlines are preserved inside the JSON string.
Write-Host "Writing secret/github/app to Vault ..."
$secretBody = @{
    data = @{
        app_id      = $AppId
        private_key = $PrivateKeyPem
        repo        = $GHRepo
    }
} | ConvertTo-Json -Depth 3
Invoke-RestMethod -Uri "$baseUrl/secret/data/github/app" -Method POST -Body $secretBody -ContentType "application/json" -Headers $headers | Out-Null
Write-Host "Secret stored at secret/data/github/app" -ForegroundColor Green

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Green
Write-Host ""
Write-Host "GitHub App credentials stored at: secret/github/app"
Write-Host "Fields: app_id, private_key, repo"
Write-Host ""
Write-Host "Next: run Step6-Create-VMSSRunner.ps1 to provision the VMSS"
