<#
.SYNOPSIS
    Provisions the GUSA GitHub Relay Azure Function and all supporting infrastructure.

.WHAT THIS CREATES
    - Azure Key Vault (kv-gusa-relay) with private access + soft-delete enabled
    - Key Vault secret: github-app-private-key  (the GitHub App PEM private key)
    - Function App (func-gusa-github-relay) on Consumption plan, PowerShell 7.4, Windows
    - System-assigned Managed Identity on the Function App
    - Key Vault RBAC: Key Vault Secrets User role for the Function App identity
    - App settings: KEY_VAULT_NAME, GITHUB_APP_ID, GITHUB_REPO
    - Function code deployed from the repo's infra/github-relay-function/ folder

.HOW THIS CHANGES THE TRIGGER CHAIN
    BEFORE: JFrog webhook -> GitHub dispatch API (static PAT stored in JFrog)
    AFTER:  JFrog webhook -> Azure Function -> GitHub App installation token (fresh, auto-expiring)

    The Function App endpoint URL + function key replace the PAT in the JFrog webhook.
    Run Step7-Create-JFrog-Webhook.ps1 with -FunctionUrl after this script completes.

.PREREQUISITES
    - az CLI logged in: az login
    - GitHub App gusa-runner-registration (App ID 3639210) must be installed on spartnick-hub org
    - GitHub App private key PEM file available locally
    - Repo cloned at $RepoRoot (infra/github-relay-function/ must exist)

.USAGE
    & ".\Deploy-GitHubRelayFunction.ps1" `
        -GitHubAppPrivateKeyPath "C:\Users\freen\Downloads\gusa-runner-registration.pem" `
        -GitHubRepo "spartnick-hub/dayforce-gusa-deployment" `
        -GitHubAppId "3639210"
#>

param(
    [Parameter(Mandatory)][string]$GitHubAppPrivateKeyPath,
    [string]$GitHubRepo        = 'spartnick-hub/dayforce-gusa-deployment',
    [string]$GitHubAppId       = '3639210',
    [string]$ResourceGroup     = 'rg-gusa-prod-east-us',
    [string]$Location          = 'eastus',
    [string]$FunctionAppName   = 'func-gusa-github-relay',
    [string]$KeyVaultName      = 'kv-gusa-relay',
    [string]$StorageAccount    = 'stgusablobeastus',
    [string]$RepoRoot          = 'D:\Dayforce\repos\dayforce-gusa-deployment-clean'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Write-Host '=== Deploy-GitHubRelayFunction.ps1 ===' -ForegroundColor Cyan
Write-Host "Function App : $FunctionAppName"
Write-Host "Key Vault    : $KeyVaultName"
Write-Host "GitHub Repo  : $GitHubRepo"
Write-Host "GitHub App ID: $GitHubAppId"
Write-Host ''

if (-not (Test-Path $GitHubAppPrivateKeyPath)) {
    throw "Private key PEM not found: $GitHubAppPrivateKeyPath. Download it from https://github.com/settings/apps/gusa-runner-registration"
}

$pem = Get-Content $GitHubAppPrivateKeyPath -Raw
if ($pem -notmatch 'BEGIN RSA PRIVATE KEY|BEGIN PRIVATE KEY') {
    throw "File at $GitHubAppPrivateKeyPath does not look like an RSA private key PEM."
}

$funcSourceDir = Join-Path $RepoRoot 'infra\github-relay-function'
if (-not (Test-Path $funcSourceDir)) {
    throw "Function source not found at $funcSourceDir. Ensure the repo is cloned."
}

$sub = az account show --query id -o tsv
if (-not $sub) { throw "Not logged in. Run: az login" }
Write-Host "Subscription : $sub" -ForegroundColor Green

Write-Host ''
Write-Host '--- Step 1: Create Key Vault ---' -ForegroundColor Yellow
$kvExists = az keyvault show --name $KeyVaultName --resource-group $ResourceGroup --query name -o tsv 2>$null
if ($kvExists) {
    Write-Host "Key Vault '$KeyVaultName' already exists." -ForegroundColor Green
} else {
    az keyvault create `
        --name              $KeyVaultName `
        --resource-group    $ResourceGroup `
        --location          $Location `
        --enable-rbac-authorization true `
        --retention-days    7 `
        --sku               standard | Out-Null
    Write-Host "Key Vault '$KeyVaultName' created." -ForegroundColor Green
}

Write-Host ''
Write-Host '--- Step 2: Store GitHub App private key in Key Vault ---' -ForegroundColor Yellow
$callerObjId = az ad signed-in-user show --query id -o tsv 2>$null
if (-not $callerObjId) {
    $callerObjId = az account show --query user.name -o tsv
}
$kvScope = "/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.KeyVault/vaults/$KeyVaultName"

az role assignment create `
    --role               "Key Vault Secrets Officer" `
    --assignee           $callerObjId `
    --scope              $kvScope | Out-Null

Start-Sleep 10

az keyvault secret set `
    --vault-name $KeyVaultName `
    --name       'github-app-private-key' `
    --value      $pem | Out-Null
Write-Host "Secret 'github-app-private-key' stored in $KeyVaultName." -ForegroundColor Green

Write-Host ''
Write-Host '--- Step 3: Create Function App ---' -ForegroundColor Yellow
$funcExists = az functionapp show --name $FunctionAppName --resource-group $ResourceGroup --query name -o tsv 2>$null
if (-not $funcExists) {
    az functionapp create `
        --name                $FunctionAppName `
        --resource-group      $ResourceGroup `
        --storage-account     $StorageAccount `
        --consumption-plan-location $Location `
        --runtime             powershell `
        --runtime-version     7.4 `
        --functions-version   4 `
        --os-type             Windows `
        --assign-identity     [system] | Out-Null
    Write-Host "Function App '$FunctionAppName' created." -ForegroundColor Green
} else {
    Write-Host "Function App '$FunctionAppName' already exists." -ForegroundColor Green
    az functionapp identity assign `
        --name           $FunctionAppName `
        --resource-group $ResourceGroup | Out-Null
}

$principalId = az functionapp show `
    --name           $FunctionAppName `
    --resource-group $ResourceGroup `
    --query          identity.principalId -o tsv

Write-Host "Managed Identity principal: $principalId" -ForegroundColor Green

Write-Host ''
Write-Host '--- Step 4: Grant Function App access to Key Vault ---' -ForegroundColor Yellow
az role assignment create `
    --role               "Key Vault Secrets User" `
    --assignee-object-id $principalId `
    --assignee-principal-type ServicePrincipal `
    --scope              $kvScope | Out-Null
Write-Host "Key Vault Secrets User role granted to Function App identity." -ForegroundColor Green

Write-Host ''
Write-Host '--- Step 5: Configure Function App settings ---' -ForegroundColor Yellow
az functionapp config appsettings set `
    --name           $FunctionAppName `
    --resource-group $ResourceGroup `
    --settings `
        "KEY_VAULT_NAME=$KeyVaultName" `
        "GITHUB_APP_ID=$GitHubAppId" `
        "GITHUB_REPO=$GitHubRepo" | Out-Null
Write-Host "App settings configured." -ForegroundColor Green

Write-Host ''
Write-Host '--- Step 6: Deploy function code ---' -ForegroundColor Yellow
$zipPath = "$env:TEMP\gusa-github-relay.zip"
Compress-Archive -Path "$funcSourceDir\*" -DestinationPath $zipPath -Force
az functionapp deployment source config-zip `
    --name           $FunctionAppName `
    --resource-group $ResourceGroup `
    --src            $zipPath | Out-Null
Remove-Item $zipPath -Force
Write-Host "Function code deployed." -ForegroundColor Green

Write-Host ''
Write-Host '--- Step 7: Retrieve function URL ---' -ForegroundColor Yellow
$functionKey = az functionapp keys list `
    --name           $FunctionAppName `
    --resource-group $ResourceGroup `
    --query          "functionKeys.default" -o tsv

$functionUrl = "https://$FunctionAppName.azurewebsites.net/api/GusaGitHubRelay?code=$functionKey"

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' DEPLOYMENT COMPLETE' -ForegroundColor Green
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host "Function URL (keep secret — this IS the credential):" -ForegroundColor Yellow
Write-Host "  $functionUrl" -ForegroundColor White
Write-Host ''
Write-Host 'Next step — update the JFrog webhook to use this URL:' -ForegroundColor Yellow
Write-Host "  & `".\Step7-Create-JFrog-Webhook.ps1`" -FunctionUrl `"$functionUrl`""
Write-Host ''
Write-Host 'Verify the function is reachable:' -ForegroundColor Yellow
Write-Host "  Invoke-RestMethod '$functionUrl' -Method POST -Body '{`"event_type`":`"relay-test`",`"client_payload`":{`"artifact_path`":`"test`",`"repo_key`":`"test`"}}' -ContentType 'application/json'"
Write-Host ''
Write-Host 'Application Insights logs:' -ForegroundColor Yellow
Write-Host "  az monitor app-insights component show -g $ResourceGroup --app $FunctionAppName"
