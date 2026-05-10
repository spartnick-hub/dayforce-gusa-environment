<#
.SYNOPSIS
    Creates the GUSA GitHub Actions self-hosted runner VMSS (vmss-gusa-ghrunner).

.PREREQUISITES
    Run Step6a-Create-GitHubApp.ps1 first to store the GitHub App credentials in HCP Vault.

.WHAT THIS CREATES
    - VMSS: vmss-gusa-ghrunner (Windows Server 2022, Standard_D2s_v3, no public IP)
    - System-assigned managed identity per instance
    - Role assignments: Contributor on RG, Storage Blob Data Contributor, Table Data Contributor
    - Custom Script Extension: Bootstrap-GHRunner.ps1 runs on every new instance

.HOW RUNNER REGISTRATION WORKS (GitHub App flow)
    1. VMSS instance starts
    2. Custom Script Extension runs Bootstrap-GHRunner.ps1 (this is where auth happens)
    3. Bootstrap uses HCP Vault AppRole (credentials in encrypted protected settings) to get a Vault token
    4. Vault token -> read secret/github/app (App ID + private key PEM)
    5. Bootstrap generates a GitHub App JWT (RS256, signed with private key, valid 10 min)
    6. JWT -> GitHub API -> installation token (valid 1 hour)
    7. Installation token -> runner registration token (valid 1 hour)
    8. Register runner with --ephemeral flag (deregisters after one job)
    9. Start GitHub Actions runner Windows service

.WHY EPHEMERAL
    Each runner instance handles exactly one workflow job then deregisters.
    Azure reimages the instance back to a clean base state before the next job.
    No stale state, no leftover artifacts, no credentials lingering between runs.

.AUTOSCALING (future)
    For POC: fixed instance count. For production, connect Azure Monitor autoscale
    to GitHub Actions queue depth via webhook + Azure Function trigger.

.USAGE
    & "D:\Dayforce\repos\hcm\gusa-pipeline\setup\Step6-Create-VMSSRunner.ps1"

.REIMAGE INSTANCES (after each POC test run - restores clean state)
    az vmss reimage --resource-group rg-gusa-prod-east-us --name vmss-gusa-ghrunner --instance-ids "*"

.SCALE RUNNER COUNT
    az vmss scale --resource-group rg-gusa-prod-east-us --name vmss-gusa-ghrunner --new-capacity 3
#>

param(
    [string]$ResourceGroup    = "rg-gusa-prod-east-us",
    [string]$Location         = "eastus",
    [string]$VmssName         = "vmss-gusa-ghrunner",
    [string]$VmSize           = "Standard_D2s_v3",
    [string]$InstanceCount    = "2",
    [string]$SubnetName       = "snet-gusa-prod",
    [string]$VnetName         = "vnet-gusa-prod-east-us",
    [string]$Subscription     = "e09a0f00-c31e-48df-a5f3-4bccf78cf898",
    [string]$GHRepo           = "spartnick-hub/dayforce-gusa-deployment",
    [string]$RunnerLabels     = "self-hosted,Windows,gusa-runner",
    [string]$ArtifactStorage  = "stgusablobeastus",
    [string]$BootstrapScript  = "D:\Dayforce\repos\hcm\gusa-pipeline\scripts\runner\Bootstrap-GHRunner.ps1",

    # HCP Vault AppRole - these go into VMSS protected settings (encrypted at rest in Azure)
    # The Secret ID is the only truly sensitive value here - it is rotatable in Vault.
    [string]$VaultAddr        = "https://vault-gusa-prod-public-vault-8632fb0b.fed357f8.z1.hashicorp.cloud:8200",
    [string]$VaultNamespace   = "admin",
    [string]$VaultRoleId      = "3a4ceeda-3d40-1b93-3a41-05ed5cbc8ab2",
    [string]$VaultSecretId    = "",  # prompted if empty - this is the sensitive value
    [string]$AdminPassword    = "",  # prompted if empty - Windows VM admin password (not used day-to-day, Bastion for access)
    [string]$DomainName       = "dayforceusa.local",
    [string]$DomainJoinUser   = "",  # AAD DC Administrators member UPN — prompted if empty
    [string]$DomainJoinPass   = "",  # prompted if empty
    [string]$GmsaAccount      = "dayforceusa\ghrunner$"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Step 6: Create VMSS GitHub Actions Runner ===" -ForegroundColor Cyan
Write-Host "VMSS     : $VmssName"
Write-Host "Size     : $VmSize  x$InstanceCount instances"
Write-Host "Repo     : $GHRepo"
Write-Host "Labels   : $RunnerLabels"
Write-Host ""

az account set --subscription $Subscription

if ([string]::IsNullOrWhiteSpace($VaultSecretId)) {
    $VaultSecretId = Read-Host "HCP Vault AppRole Secret ID (HC_VAULT_SECRET_ID - stored encrypted in VMSS protected settings)"
}
if ([string]::IsNullOrWhiteSpace($VaultSecretId)) { throw "Vault Secret ID is required." }

# Check if VMSS already exists — idempotent, safe to re-run
$vmssExists = az vmss show --resource-group $ResourceGroup --name $VmssName --query name -o tsv 2>$null
if ($vmssExists) {
    Write-Host "VMSS '$VmssName' already exists — skipping create, updating extension only." -ForegroundColor Yellow
} else {
    if ([string]::IsNullOrWhiteSpace($AdminPassword)) {
        $AdminPassword = Read-Host "VMSS admin password (Windows VM requirement - 12+ chars, upper+lower+digit+special)"
    }
    if ([string]::IsNullOrWhiteSpace($AdminPassword)) { throw "Admin password is required." }
}

$SubnetId = az network vnet subnet show `
    --resource-group $ResourceGroup `
    --vnet-name      $VnetName `
    --name           $SubnetName `
    --query id -o tsv
Write-Host "Subnet   : $SubnetId"

# ==============================================================================
# 1. Create the VMSS  (skipped automatically if VMSS already exists)
# ==============================================================================
if (-not $vmssExists) {
    Write-Host ""
    Write-Host "Creating VMSS $VmssName ..." -ForegroundColor Cyan

    az vmss create `
        --resource-group        $ResourceGroup `
        --name                  $VmssName `
        --location              $Location `
        --vm-sku                $VmSize `
        --instance-count        $InstanceCount `
        --orchestration-mode    Uniform `
        --image                 "Win2022Datacenter" `
        --admin-username        "gusarunneradmin" `
        --admin-password        $AdminPassword `
        --subnet                $SubnetId `
        --public-ip-address     '""' `
        --load-balancer         '""' `
        --upgrade-policy-mode   Manual `
        --computer-name-prefix  "gusarnnr" `
        --os-disk-size-gb       128
    # NOTE: No --assign-identity here.
    # The workflow jobs that run on these runners authenticate to Azure via OIDC federated
    # credential (AZURE_CLIENT_ID / AZURE_TENANT_ID / AZURE_SUBSCRIPTION_ID in GitHub secrets).
    # That is the correct and only auth path needed — VMSS managed identity is not required.

    if ($LASTEXITCODE -ne 0) { throw "VMSS creation failed — aborting. Fix the error above before continuing." }
    Write-Host "VMSS created." -ForegroundColor Green
}

# ==============================================================================
# 2. Add JsonADDomainExtension — domain-join every VMSS instance to dayforceusa.local
# Required so the runner can use the gMSA account (dayforceusa\ghrunner$).
# Domain join account must be a member of AAD DC Administrators in Entra ID.
# ==============================================================================
if ([string]::IsNullOrWhiteSpace($DomainJoinUser)) {
    $DomainJoinUser = Read-Host "Domain join account UPN (must be member of AAD DC Administrators)"
}
if ([string]::IsNullOrWhiteSpace($DomainJoinPass)) {
    $DomainJoinPass = Read-Host "Domain join account password"
}

Write-Host "Adding JsonADDomainExtension (domain join) ..." -ForegroundColor Cyan

$domainPublic    = [System.IO.Path]::GetTempFileName()
$domainProtected = [System.IO.Path]::GetTempFileName()

@{ Name = $DomainName; User = $DomainJoinUser; Restart = "true"; Options = "3" } |
    ConvertTo-Json | Set-Content $domainPublic -Encoding utf8

@{ Password = $DomainJoinPass } |
    ConvertTo-Json | Set-Content $domainProtected -Encoding utf8

az vmss extension set `
    --resource-group     $ResourceGroup `
    --vmss-name          $VmssName `
    --name               JsonADDomainExtension `
    --publisher          Microsoft.Compute `
    --version            1.3 `
    --settings           "@$domainPublic" `
    --protected-settings "@$domainProtected"

Remove-Item $domainPublic, $domainProtected -ErrorAction SilentlyContinue
Write-Host "Domain join extension added." -ForegroundColor Green

# ==============================================================================
# 3. Upload Bootstrap-GHRunner.ps1 to blob storage
# ==============================================================================
Write-Host ""
Write-Host "Uploading Bootstrap-GHRunner.ps1 to blob storage ..." -ForegroundColor Cyan

# Use account key for upload and SAS generation - bypasses data plane RBAC
# (Contributor role allows getting the key; --auth-mode login requires explicit data plane role)
$AccountKey = az storage account keys list `
    --account-name   $ArtifactStorage `
    --resource-group $ResourceGroup `
    --query          "[0].value" -o tsv

az storage blob upload `
    --account-name   $ArtifactStorage `
    --container-name "deployments" `
    --name           "runner/Bootstrap-GHRunner.ps1" `
    --file           $BootstrapScript `
    --account-key    $AccountKey `
    --overwrite

Write-Host "Script uploaded." -ForegroundColor Green

# Generate a SAS URL valid for 2 years using account key (no 7-day limit unlike user delegation SAS)
$Expiry  = (Get-Date).AddYears(2).ToString("yyyy-MM-ddTHH:mm:ssZ")
$BlobUrl = az storage blob generate-sas `
    --account-name   $ArtifactStorage `
    --container-name "deployments" `
    --name           "runner/Bootstrap-GHRunner.ps1" `
    --permissions    r `
    --expiry         $Expiry `
    --account-key    $AccountKey `
    --full-uri -o tsv

# ==============================================================================
# 4. Deploy Custom Script Extension
# ==============================================================================
# Everything goes in PROTECTED settings (encrypted at rest in Azure).
# Public settings are intentionally empty — no sensitive data in plain text.
#
# WHY no -File flag:
#   CSE downloads the script to a CSE-managed temp directory but PowerShell's -File
#   does NOT reliably search the current directory across all Windows CSE versions.
#   Instead, the commandToExecute downloads the script itself to a known absolute path
#   (C:\DfRunner\) using .NET WebClient, then runs it from there. This is deterministic
#   regardless of where CSE sets the working directory.
#
# Security note: $BlobUrl is a read-only account-key SAS — already effectively public.
#   Storing it in protected settings just adds an extra encryption layer at no cost.
Write-Host ""
Write-Host "Installing Custom Script Extension on VMSS ..." -ForegroundColor Cyan

# Build the commandToExecute as a PowerShell -Command string.
# Double-quotes inside the outer double-quoted JSON string must be escaped as \".
# We use single quotes for inner strings to avoid the escaping cascade.
$runnerDir = 'C:\DfRunner'
$scriptDest = "$runnerDir\Bootstrap-GHRunner.ps1"

# The command:
#   1. Creates C:\DfRunner\
#   2. Downloads Bootstrap-GHRunner.ps1 from blob (SAS URL) to that known path
#   3. Runs the script with all parameters
$psCommand = [string]::Join('; ', @(
    "New-Item '$runnerDir' -ItemType Directory -Force | Out-Null",
    "[Net.WebClient]::new().DownloadFile('$BlobUrl', '$scriptDest')",
    "& '$scriptDest' -GHRepo '$GHRepo' -RunnerLabels '$RunnerLabels' -VaultAddr '$VaultAddr' -VaultNamespace '$VaultNamespace' -VaultRoleId '$VaultRoleId' -VaultSecretId '$VaultSecretId' -GmsaAccount '$GmsaAccount'"
))

# Write JSON to temp files - avoids PowerShell + az CLI inline JSON quoting issues
$PublicJson    = [System.IO.Path]::GetTempFileName()
$ProtectedJson = [System.IO.Path]::GetTempFileName()

@{} | ConvertTo-Json | Set-Content $PublicJson -Encoding utf8   # empty public settings

@{
    commandToExecute = "powershell -ExecutionPolicy Bypass -NoProfile -Command `"$psCommand`""
} | ConvertTo-Json -Depth 3 | Set-Content $ProtectedJson -Encoding utf8

az vmss extension set `
    --resource-group     $ResourceGroup `
    --vmss-name          $VmssName `
    --name               CustomScriptExtension `
    --publisher          Microsoft.Compute `
    --version            1.10 `
    --settings           "@$PublicJson" `
    --protected-settings "@$ProtectedJson"

Remove-Item $PublicJson, $ProtectedJson -ErrorAction SilentlyContinue

Write-Host "Custom Script Extension deployed." -ForegroundColor Green

# Apply extension to all existing instances (reimages clean each time)
Write-Host "Updating all VMSS instances ..." -ForegroundColor Cyan
az vmss update-instances --resource-group $ResourceGroup --name $VmssName --instance-ids "*"

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Green
Write-Host ""
Write-Host "Runners will appear at (within ~5 min):"
Write-Host "  https://github.com/$GHRepo/settings/actions/runners"
Write-Host ""
Write-Host "Reimage all instances after a test run:"
Write-Host "  az vmss reimage --resource-group $ResourceGroup --name $VmssName --instance-ids `"*`""
Write-Host ""
Write-Host "Scale runner count:"
Write-Host "  az vmss scale --resource-group $ResourceGroup --name $VmssName --new-capacity 3"
