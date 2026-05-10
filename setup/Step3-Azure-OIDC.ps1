
$ErrorActionPreference = 'Stop'

Write-Host "=== Step 3: Azure OIDC App Registration ===" -ForegroundColor Cyan
Write-Host "Subscription : e09a0f00-c31e-48df-a5f3-4bccf78cf898"
Write-Host "Tenant       : 55f5d6da-59e4-4599-ba22-a97fc476f3aa"

az account set --subscription e09a0f00-c31e-48df-a5f3-4bccf78cf898

$app   = az ad app create --display-name "gusa-github-actions-oidc" | ConvertFrom-Json
$appId = $app.appId
Write-Host "App Registration created: $appId" -ForegroundColor Green

az ad sp create --id $appId | Out-Null
Write-Host "Service Principal created." -ForegroundColor Green

$credJson = @{
    name      = "gusa-github-production"
    issuer    = "https://token.actions.githubusercontent.com"
    subject   = "repo:spartnick-hub/dayforce-gusa-deployment:environment:production"
    audiences = @("api://AzureADTokenExchange")
} | ConvertTo-Json -Compress

$credPath = "$env:TEMP\gusa-fed-cred.json"
$credJson | Set-Content $credPath -Encoding UTF8

az ad app federated-credential create --id $appId --parameters "@$credPath"
Remove-Item $credPath -Force -ErrorAction SilentlyContinue
Write-Host "Federated credential created." -ForegroundColor Green

$sub   = "e09a0f00-c31e-48df-a5f3-4bccf78cf898"
$rg    = "/subscriptions/$sub/resourceGroups/rg-gusa-prod-east-us"
$stgA  = "/subscriptions/$sub/resourceGroups/rg-gusa-prod-east-us/providers/Microsoft.Storage/storageAccounts/stgusablobeastus"
$stgB  = "/subscriptions/$sub/resourceGroups/rg-gusa-prod-east-us/providers/Microsoft.Storage/storageAccounts/stgusastatetable"

az role assignment create --assignee $appId --role Contributor --scope $rg
Write-Host "Contributor on rg-gusa-prod-east-us assigned." -ForegroundColor Green

az role assignment create --assignee $appId --role "Storage Blob Data Contributor" --scope $stgA
Write-Host "Storage Blob Data Contributor on stgusaprodeastus assigned." -ForegroundColor Green

az role assignment create --assignee $appId --role "Storage Table Data Contributor" --scope $stgB
Write-Host "Storage Table Data Contributor on stgusastatetable assigned." -ForegroundColor Green

az storage container create `
    --name           deployments `
    --account-name   stgusablobeastus `
    --auth-mode      login

if ($LASTEXITCODE -ne 0) {
    Write-Warning "'deployments' container creation FAILED (exit $LASTEXITCODE). Run manually: az storage container create --name deployments --account-name stgusablobeastus --auth-mode login"
} else {
    Write-Host "'deployments' container created." -ForegroundColor Green
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Yellow
Write-Host "DONE.  Add this secret to GitHub:" -ForegroundColor Yellow
Write-Host "  AZURE_CLIENT_ID = $appId" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Yellow
