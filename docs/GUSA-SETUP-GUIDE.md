# GUSA CD Pipeline — Complete Setup Guide

**Audience**: Anyone who needs to stand up this pipeline in a new Azure subscription / GitHub org.
**Architecture**: GitHub Actions → new-VM blue/green with Azure Load Balancer (Dayforce .NET 4.7.2 monolith)
**Environments covered**: GUSA Production (first). Each new environment = repeat Steps 1–6 with different values; no workflow YAML changes.

---

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| Azure CLI | ≥ 2.55 | `winget install Microsoft.AzureCLI` |
| PowerShell | ≥ 7.4 | `winget install Microsoft.PowerShell` |
| JFrog CLI | ≥ 2.99 | Download from [jfrog.com/getcli](https://jfrog.com/getcli/) |
| GitHub CLI | ≥ 2.45 | `winget install GitHub.cli` |

---

## Step 1 — Azure Infrastructure

### 1.1 Resource Group, VNet, Subnets

```powershell
az login --tenant <TENANT_ID>
az account set --subscription <SUBSCRIPTION_ID>

az group create --name rg-<ENV>-prod-<REGION> --location <REGION>

az network vnet create `
  --resource-group rg-<ENV>-prod-<REGION> `
  --name vnet-<ENV>-prod-<REGION> `
  --address-prefixes 10.10.0.0/16

az network vnet subnet create `
  --resource-group rg-<ENV>-prod-<REGION> `
  --vnet-name vnet-<ENV>-prod-<REGION> `
  --name snet-<ENV>-prod `
  --address-prefixes 10.10.1.0/24

az network vnet subnet create `
  --resource-group rg-<ENV>-prod-<REGION> `
  --vnet-name vnet-<ENV>-prod-<REGION> `
  --name AzureBastionSubnet `
  --address-prefixes 10.10.0.0/26
```

### 1.2 NAT Gateway (outbound internet for private VMs)

```powershell
az network public-ip create `
  --resource-group rg-<ENV>-prod-<REGION> `
  --name pip-nat-<ENV>-prod-<REGION> `
  --sku Standard --allocation-method Static

az network nat gateway create `
  --resource-group rg-<ENV>-prod-<REGION> `
  --name nat-<ENV>-prod-<REGION> `
  --public-ip-addresses pip-nat-<ENV>-prod-<REGION>

az network vnet subnet update `
  --resource-group rg-<ENV>-prod-<REGION> `
  --vnet-name vnet-<ENV>-prod-<REGION> `
  --name snet-<ENV>-prod `
  --nat-gateway nat-<ENV>-prod-<REGION>
```

### 1.3 Azure Bastion (admin access — no public IPs on VMs)

```powershell
az network public-ip create `
  --resource-group rg-<ENV>-prod-<REGION> `
  --name pip-bastion-<ENV>-prod-<REGION> `
  --sku Standard --allocation-method Static

az network bastion create `
  --resource-group rg-<ENV>-prod-<REGION> `
  --name bastion-<ENV>-prod-<REGION> `
  --public-ip-address pip-bastion-<ENV>-prod-<REGION> `
  --vnet-name vnet-<ENV>-prod-<REGION> `
  --location <REGION>
```

### 1.4 Azure Load Balancer (Standard Internal)

```powershell
az network lb create `
  --resource-group rg-<ENV>-prod-<REGION> `
  --name lb-<ENV>-prod-<REGION> `
  --sku Standard `
  --frontend-ip-name fe-<ENV>-appserver `
  --private-ip-address 10.10.1.10 `
  --vnet-name vnet-<ENV>-prod-<REGION> `
  --subnet snet-<ENV>-prod `
  --backend-pool-name be-<ENV>-appserver

az network lb probe create `
  --resource-group rg-<ENV>-prod-<REGION> `
  --lb-name lb-<ENV>-prod-<REGION> `
  --name probe-http-health `
  --protocol Http `
  --port 80 `
  --path /health

az network lb rule create `
  --resource-group rg-<ENV>-prod-<REGION> `
  --lb-name lb-<ENV>-prod-<REGION> `
  --name rule-http `
  --protocol Tcp `
  --frontend-port 80 `
  --backend-port 80 `
  --frontend-ip-name fe-<ENV>-appserver `
  --backend-pool-name be-<ENV>-appserver `
  --probe-name probe-http-health

az network lb rule create `
  --resource-group rg-<ENV>-prod-<REGION> `
  --lb-name lb-<ENV>-prod-<REGION> `
  --name rule-https `
  --protocol Tcp `
  --frontend-port 443 `
  --backend-port 443 `
  --frontend-ip-name fe-<ENV>-appserver `
  --backend-pool-name be-<ENV>-appserver `
  --probe-name probe-http-health
```

### 1.5 Storage Accounts

```powershell
# Artifact staging (artifact zip + scripts delivered to new VMs)
az storage account create `
  --resource-group rg-<ENV>-prod-<REGION> `
  --name stg<env>prodeastus `
  --sku Premium_LRS `
  --kind FileStorage `
  --location <REGION>

az storage container create `
  --account-name stg<env>prodeastus `
  --name deployments `
  --auth-mode login

# DeploymentState table (version authority)
az storage account create `
  --resource-group rg-<ENV>-prod-<REGION> `
  --name stg<env>statetable `
  --sku Standard_LRS `
  --kind StorageV2 `
  --location <REGION>

az storage table create `
  --account-name stg<env>statetable `
  --name DeploymentState `
  --auth-mode login
```

### 1.6 Initial DeploymentState Row (seed for first deployment)

The first deployment needs an existing "old" VM or an empty state entry. If there is a VM already serving traffic, insert its name:

```powershell
# Run AFTER the initial "old" VM exists with name vm-<ENV>-appserver-01
# This lets the pipeline know which VM is currently live so it can decommission it on first real deployment

$entity = @{
    PartitionKey = "wwwprod"
    RowKey       = "web"
    VmName       = "vm-<ENV>-appserver-01"
    BuildVersion = "0.0.0"
    LastUpdated  = (Get-Date -Format 'o')
} | ConvertTo-Json

$entity | Set-Content "$env:TEMP\seed-state.json"
az storage entity insert `
    --account-name stg<env>statetable `
    --table-name   DeploymentState `
    --entity       @"$env:TEMP\seed-state.json" `
    --if-exists    replace `
    --auth-mode    login
```

---

## Step 2 — JFrog Artifactory

### 2.1 Create Repos

Log in to https://<org>.jfrog.io → Administration → Repositories → Add Repository → Local:

| Name | Package type |
|---|---|
| `dfcore-dev-local` | Generic |
| `dfcore-qa-local` | Generic |
| `dfcore-preprod-local` | Generic |
| `dfcore-prod-local` | Generic |

### 2.2 Configure JFrog CLI

```powershell
jf config add <server-id> `
  --url https://<org>.jfrog.io `
  --access-token <token> `
  --interactive=false
```

### 2.3 Upload First Artifact

Artifact naming convention: `<ArtifactZipPrefix>-<version>.zip` placed at `<JFROG_PROD_REPO>/<JFROG_ARTIFACT_FOLDER>/<version>/`.

```powershell
# Example: DFCore-1.0.0.zip
jf rt upload `
  "C:\path\to\DFCore-1.0.0.zip" `
  "dfcore-prod-local/Dayforce/1.0.0/DFCore-1.0.0.zip" `
  --server-id <server-id>
```

**Or use the setup script**: `setup\Step4-Upload-Artifact.ps1`

### 2.4 JFrog OIDC (future — when upgraded to Enterprise X)

1. JFrog Admin → Security → Manage Integrations → GitHub → Add Repository: `<org>/dayforce-gusa-deployment`
2. GitHub Actions secret `JFROG_OIDC_PROVIDER_NAME` = name from JFrog
3. Replace `JFROG_ACCESS_TOKEN` header auth with OIDC exchange in `_core-deploy.yml` pre-deploy-validation

---

## Step 3 — HCP Vault

### 3.1 Create Cluster

HCP portal → Vault → Create Cluster → Dedicated → select region.

### 3.2 Configure AppRole + Secret

```bash
# Connect via admin token (HCP portal → cluster → Access Vault → Generate admin token)
export VAULT_ADDR=https://<cluster-public-url>:8200
export VAULT_NAMESPACE=admin
export VAULT_TOKEN=<admin-token>

vault secrets enable -path=secret kv-v2

vault policy write templated_secret_read_write - <<EOF
path "secret/data/codesigning/cert" { capabilities = ["create","read","update","delete"] }
path "secret/metadata/codesigning/cert" { capabilities = ["read","list","delete"] }
EOF

vault auth enable approle

vault write auth/approle/role/app-read-write \
  token_policies="templated_secret_read_write" \
  token_ttl=1h token_max_ttl=4h

vault read -field=role_id auth/approle/role/app-read-write/role-id
vault write -f -field=secret_id auth/approle/role/app-read-write/secret-id

# Store the cert thumbprint
vault kv put secret/codesigning/cert thumbprint=<cert-thumbprint>
```

### 3.3 GitHub Secrets from Vault

| Secret | Source |
|---|---|
| `VAULT_ADDR` | Cluster public URL |
| `VAULT_NAMESPACE` | `admin` |
| `VAULT_ROLE_ID` | Output of role-id command |
| `VAULT_SECRET_ID` | Output of secret-id command |

---

## Step 4 — Azure OIDC for GitHub Actions

**Run `setup\Step3-Azure-OIDC.ps1`** (requires `az login --tenant <TENANT_ID>` first) — or manually:

```powershell
# Must be logged in to correct tenant + subscription first
az login --tenant <TENANT_ID>
az account set --subscription <SUBSCRIPTION_ID>

# 1. App Registration
$app   = az ad app create --display-name "<env>-github-actions-oidc" | ConvertFrom-Json
$appId = $app.appId

# 2. Service Principal
az ad sp create --id $appId

# 3. Federated credential — write JSON to file (inline fails in PS due to quoting)
@{
    name      = "<env>-github-production"
    issuer    = "https://token.actions.githubusercontent.com"
    subject   = "repo:<GITHUB_ORG>/<GITHUB_REPO>:environment:<ENVIRONMENT_NAME>"
    audiences = @("api://AzureADTokenExchange")
} | ConvertTo-Json | Set-Content "$env:TEMP\fed-cred.json"

az ad app federated-credential create --id $appId --parameters "@$env:TEMP\fed-cred.json"

# 4. Role assignments
$sub = "<SUBSCRIPTION_ID>"
$rg  = "/subscriptions/$sub/resourceGroups/rg-<ENV>-prod-<REGION>"
az role assignment create --assignee $appId --role Contributor --scope $rg
az role assignment create --assignee $appId `
  --role "Storage Blob Data Contributor" `
  --scope "$rg/providers/Microsoft.Storage/storageAccounts/stg<env>prodeastus"
az role assignment create --assignee $appId `
  --role "Storage Table Data Contributor" `
  --scope "$rg/providers/Microsoft.Storage/storageAccounts/stg<env>statetable"

Write-Host "Add GitHub secret: AZURE_CLIENT_ID = $appId"
```

---

## Step 5 — VM Base Image

The pipeline provisions new VMs from a base image that already has all tools installed. This avoids per-deployment tool installation time.

### 5.1 What the Base Image Must Have

- Windows Server 2022 Datacenter Azure Edition
- IIS + .NET 4.8 (Web Server role + all features from `Install-WindowsFeature`)
- 7-Zip at `C:\Program Files\7-Zip\7z.exe`
- Vault CLI at `C:\HashiCorp\Vault\vault.exe`
- Azure CLI at `C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd`
- F: drive (Premium SSD, NTFS, label "Dayforce")
- Folder structure: `F:\Dayforce\Site\prod`, `F:\Dayforce\Bje\prod`, `F:\Dayforce\log\wwwprod`
- (Optionally) gMSA `dfGusaAppPool$` configured — or configure at deploy time

### 5.2 Capture to Compute Gallery

```powershell
# On the base VM (via Bastion) — sysprep + generalize
C:\Windows\System32\Sysprep\sysprep.exe /oobe /generalize /quiet /shutdown

# After shutdown, in Azure CLI
az sig create `
  --resource-group rg-<ENV>-prod-<REGION> `
  --gallery-name gal<ENV>prod

az sig image-definition create `
  --resource-group rg-<ENV>-prod-<REGION> `
  --gallery-name gal<ENV>prod `
  --gallery-image-definition DayforceProdAppServer `
  --publisher Dayforce --offer DFCore --sku WS2022 `
  --os-type Windows

az sig image-version create `
  --resource-group rg-<ENV>-prod-<REGION> `
  --gallery-name gal<ENV>prod `
  --gallery-image-definition DayforceProdAppServer `
  --gallery-image-version 1.0.0 `
  --managed-image /subscriptions/<SUB>/resourceGroups/<RG>/providers/Microsoft.Compute/virtualMachines/vm-baseimage-01 `
  --target-regions "<REGION>=1"

# Get the image ID — this is APP_SERVER_BASE_IMAGE
az sig image-version show `
  --resource-group rg-<ENV>-prod-<REGION> `
  --gallery-name gal<ENV>prod `
  --gallery-image-definition DayforceProdAppServer `
  --gallery-image-version 1.0.0 `
  --query id -o tsv
```

---

## Step 6 — GitHub Setup

### 6.1 Repository

```bash
gh repo create <GITHUB_ORG>/dayforce-<env>-deployment --private
git remote add origin https://github.com/<GITHUB_ORG>/dayforce-<env>-deployment.git
```

Copy pipeline files from `gusa-pipeline/` into the repo root:

```
.github/workflows/_core-deploy.yml
.github/workflows/deploy-<env>.yml
scripts/
```

### 6.2 Environments

```bash
gh api repos/<GITHUB_ORG>/dayforce-<env>-deployment/environments/production \
  --method PUT \
  --field wait_timer=0 \
  --field reviewers='[{"type":"User","id":<user-id>},{"type":"User","id":<user-id>}]'
```

Or via GitHub UI: Settings → Environments → New environment → **production** → Add 2 required reviewers.

### 6.3 Environment Variables

Go to Settings → Environments → production → Environment variables. Add every row from `environments/<env>-prod.vars.md`.

```bash
# Bulk-set with GitHub CLI (one per line):
gh variable set ENV_NAME --body "wwwprod" --env production --repo <GITHUB_ORG>/dayforce-<env>-deployment
gh variable set RESOURCE_GROUP --body "rg-gusa-prod-east-us" --env production ...
# (repeat for all vars)
```

### 6.4 Secrets

```bash
gh secret set AZURE_CLIENT_ID --body "<appId>" --env production --repo <GITHUB_ORG>/dayforce-<env>-deployment
gh secret set AZURE_TENANT_ID --body "<tenantId>" --env production ...
gh secret set AZURE_SUBSCRIPTION_ID --body "<subId>" --env production ...
gh secret set JFROG_URL --body "https://<org>.jfrog.io" --env production ...
gh secret set JFROG_ACCESS_TOKEN --body "<token>" --env production ...
gh secret set VAULT_ADDR --body "https://..." --env production ...
gh secret set VAULT_NAMESPACE --body "admin" --env production ...
gh secret set VAULT_ROLE_ID --body "<role-id>" --env production ...
gh secret set VAULT_SECRET_ID --body "<secret-id>" --env production ...
gh secret set STATE_STORAGE_ACCOUNT --body "stg<env>statetable" --env production ...
gh secret set LB_NAME --body "lb-<env>-prod-<region>" --env production ...
gh secret set LB_BACKEND_POOL --body "be-<env>-appserver" --env production ...
gh secret set APP_SERVER_BASE_IMAGE --body "<image-resource-id>" --env production ...
gh secret set APP_POOL_GMSA --body "dfGusaAppPool$" --env production ...
```

### 6.5 Self-Hosted Runner (VMSS)

The GitHub Actions runner must be a Windows VM (or VMSS) in the same VNet as the app server VMs — so it can reach Azure resources without public IPs.

Runner requirements:
- Domain joined to `<DOMAIN>` or configured with gMSA
- Azure CLI installed and able to authenticate (will use OIDC token from workflow)
- 7-Zip, Vault CLI, Chrome + ChromeDriver installed
- Labels: `self-hosted`, `Windows`, `<env>-runner`

```bash
# Register with GitHub (run on the runner VM)
mkdir actions-runner; cd actions-runner
Invoke-WebRequest -Uri https://github.com/actions/runner/releases/download/v2.317.0/actions-runner-win-x64-2.317.0.zip -OutFile runner.zip
Expand-Archive runner.zip .
.\config.cmd --url https://github.com/<GITHUB_ORG>/dayforce-<env>-deployment `
  --token <RUNNER_TOKEN> `
  --labels "self-hosted,Windows,<env>-runner" `
  --runasservice
.\run.cmd
```

---

## Step 7 — Testing the Pipeline

### 7.1 Fail-Fast Smoke Test (unsigned artifact)

1. Upload an unsigned zip to JFrog (`dfcore-prod-local/Dayforce/0.0.1/DFCore-0.0.1.zip`)
2. Trigger `deploy-<env>.yml` with version `0.0.1`
3. Expected: workflow fails at **Verify code signing** step — no VMs provisioned

### 7.2 Full Happy-Path Test

1. Upload a properly signed zip to JFrog (version `1.0.0`)
2. Trigger `deploy-<env>.yml` — leave version blank to auto-resolve latest
3. Approve the 2-person gate
4. Observe: new VM provisioned, artifact deployed, DB migrated, smoke test passes, LB swapped, old VM decommissioned
5. Verify `DeploymentState` table row updated to new VM name

### 7.3 Rollback Test

1. Deploy a version with a deliberately broken smoke test endpoint
2. Observe: smoke test fails → rollback job removes new VM from LB, restores DB snapshot, deletes new VM
3. Verify old VM still serving traffic, `DeploymentState` unchanged

---

## Adding a New Environment

To add GC Canada production (or any other environment):

1. **Azure**: Repeat Steps 1–5 with `gc` prefix, `canadacentral` region
2. **JFrog**: Same instance — just a new repo key if needed
3. **Vault**: Same cluster or new — create new AppRole + secret path
4. **GitHub**: Create environment `gc-production`, set all vars + secrets with GC values
5. **Workflow caller**: Copy `deploy-gusa.yml` → `deploy-gc.yml`, change `environment: production` → `environment: gc-production`
6. **No changes** to `_core-deploy.yml` or any PowerShell script

---

## File Reference

```
gusa-pipeline/
├── .github/
│   └── workflows/
│       ├── _core-deploy.yml          ← Reusable core — all logic lives here
│       └── deploy-gusa.yml           ← GUSA-specific trigger + env binding
├── environments/
│   └── gusa-prod.vars.md             ← Full vars + secrets reference for GUSA
├── scripts/
│   ├── common/
│   │   ├── Get-DeploymentState.ps1
│   │   ├── Set-DeploymentState.ps1
│   │   └── Verify-CodeSigning.ps1
│   ├── web/
│   │   ├── Provision-AppServerVM.ps1
│   │   ├── Bootstrap-NewVM.ps1
│   │   ├── Deploy-WebArtifacts.ps1
│   │   ├── Set-LoadBalancerBackend.ps1
│   │   ├── Invoke-WebSmokeTest.ps1
│   │   ├── Stop-AppPools.ps1
│   │   └── Start-AppPools.ps1
│   ├── bje/
│   │   ├── Provision-BJEServerVM.ps1
│   │   ├── Bootstrap-BJENewVM.ps1
│   │   └── Deploy-BJEArtifacts.ps1
│   └── db/
│       ├── Backup-Database.ps1
│       ├── Deploy-Database.ps1
│       └── Rollback-Database.ps1
└── setup/
    ├── Step3-Azure-OIDC.ps1          ← Run once per environment
    └── Step4-Upload-Artifact.ps1     ← Run once to seed JFrog
```
