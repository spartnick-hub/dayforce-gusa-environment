# GUSA Key Values and Configuration Reference

Last updated: 2026-05-07

---

## Azure

| Key | Value |
|---|---|
| Subscription ID | `e09a0f00-c31e-48df-a5f3-4bccf78cf898` |
| Tenant ID | `55f5d6da-59e4-4599-ba22-a97fc476f3aa` |
| Resource Group | `rg-gusa-prod-east-us` |
| Region | `East US` |
| VNet | `vnet-gusa-prod-east-us` |
| Address space | `10.10.0.0/16` |
| Subnet — VMs/VMSS | `snet-gusa-prod` — `10.10.1.0/24` |
| Subnet — Entra DS | `snet-gusa-entra-domain-svc` — `10.10.3.0/24` |
| Subnet — Bastion | `AzureBastionSubnet` — `10.10.0.0/26` |
| Bastion | `bastion-gusa-prod-east-us` |
| Bastion Public IP | `vnet-gusa-prod-east-us-bastion` |
| NAT Gateway | `nat-gusa-prod-east-us` |
| NAT Public IP | `pip-nat-gusa-prod-east-us` |
| Load Balancer | `lb-gusa-prod-east-us` (TBD — Standard Internal SKU) |

---

## App Server VM (current/old "blue" — `vm-gusa-appserver-01`)

| Key | Value |
|---|---|
| VM name | `vm-gusa-appserver-01` |
| Computer name | `vm-gusa-appserv` |
| Private IP | `10.10.1.4` |
| Size | `Standard_D4s_v3` (4 vCPU, 16 GiB) |
| OS | Windows Server 2022 Datacenter Azure Edition |
| Subnet | `snet-gusa-prod` |
| Admin username | `gusaadmin` |
| F: drive | 32 GiB Premium SSD, NTFS, label "Dayforce" |

### New-VM Provisioning (blue/green)

| Key | Value |
|---|---|
| Base image source | TBD — Azure Compute Gallery or Marketplace WS2022 |
| New VM naming | `vm-gusa-appserver-{blue or green}-{yyyyMMddHHmm}` |
| New VM size | `Standard_D4s_v3` |
| New VM subnet | `snet-gusa-prod` |
| New VM managed identity | System-assigned |
| LB backend pool | `be-gusa-appserver` |
| LB health probe | HTTP port 80 `/health` |

---

## Domain / Identity

| Key | Value |
|---|---|
| AD Domain | `dayforceusa.local` |
| gMSA — runner | `ghrunner$` |
| gMSA — app pool | `dfGusaAppPool$` |

---

## JFrog Artifactory

| Key | Value |
|---|---|
| URL | `https://freenferal.jfrog.io` |
| Admin username | `contact@feralhousewife.co` |
| CLI location (local dev) | `$env:USERPROFILE\jf.exe` |
| CLI location (app server) | `C:\HashiCorp\jf.exe` |
| CLI server ID | `freenferal` |
| Dev repo | `dfcore-dev-local` |
| QA repo | `dfcore-qa-local` |
| PreProd repo | `dfcore-preprod-local` |
| Prod repo | `dfcore-prod-local` |
| Artifact files (inside zip) | `web.rar`, `bje.rar`, `db.rar`, `AcceptanceTests.rar`, `DeployerTools.rar` |
| Auth method (GitHub Actions prod) | **OIDC federated token** (no static key) |
| Auth method (Octopus non-prod/pre-prod) | Access Token (Octopus encrypted variable) |
| OIDC audience | `jfrog-github` |
| OIDC issuer | `https://token.actions.githubusercontent.com` |

---

## GitHub

| Key | Value |
|---|---|
| POC workflow repo | `spartnick-hub/dayforce-gusa-deployment` |
| GC source ref repo | `demo-hcm/dfgcprddply` |
| GC deployment repo | `demo-hcm/dfdply` |
| Org | `demo-hcm` |
| Environments | `production` (2 reviewers), `static-production` (1), `static-production-cleanup` (1) |

---

## File Paths (App Server VM)

| Key | Value |
|---|---|
| Base path | `F:\Dayforce\` |
| Web root (served by IIS) | `F:\Dayforce\Site\prod` |
| Log path | `F:\Dayforce\log\wwwprod\` |
| Static content | `F:\Dayforce\Site\Static` |
| Artifact staging | `C:\DfGusaStaging\{version}\` |
| Backup storage (web) | `G:\` (web-blue share) / `H:\` (web-green share) |
| Backup storage (BJE) | `I:\` (bje-blue share) / `J:\` (bje-green share) |

**Note**: In new-VM blue/green model, F:\Dayforce\Site\prod is the active app directory on each VM. Blue/green is now at VM level, not directory level. Azure Files shares are used for backup/restore purposes.

---

## IIS / Application

| Key | Value |
|---|---|
| IIS site name | `wwwprod` |
| App pool prefix | `wwwprod_` |
| App pools | `wwwprod_Api`, `wwwprod_MyDayforce`, `wwwprod_AdminService`, etc. |
| Static app pool | `wwwprod_Static` |
| Web domain | `www.dayforcenextgen.gov` |
| Environment name | `wwwprod` |
| Control DB | `prodcontrol` |

---

## Storage Accounts

| Key | Value |
|---|---|
| Premium file storage (file shares only — NOT for blobs) | `stgusaprodeastus` |
| Blob artifact staging (Standard GPv2) | `stgusablobeastus` |
| File shares | `web-blue` (100 GiB), `web-green` (100 GiB), `bje-blue` (50 GiB), `bje-green` (50 GiB) |
| State/version tracking | `stgusastatetable` |
| State table name | `DeploymentState` |
| State storage key | (stored in Key Vault / GitHub secret) |

---

## HCP Vault Dedicated

| Key | Value |
|---|---|
| Mode | HCP Vault Dedicated (KV v2 template) |
| Cluster ID | `vault-gusa-prod` |
| Public URL | `https://vault-gusa-prod-public-vault-8632fb0b.fed357f8.z1.hashicorp.cloud:8200` |
| HTTP UI URL | `https://vault-gusa-prod-http-vault-45ada8c9.j.cloud.hashicorp.com` |
| Namespace | `admin` |
| Auth method | AppRole |
| AppRole name | `app-read-write` |
| Role ID | `3a4ceeda-3d40-1b93-3a41-05ed5cbc8ab2` |
| Secret ID | `a1c1547c-8ef3-8457-fe63-bfb0b4fc21aa` |
| Policy | `templated_secret_read_write` |
| Secret path | `secret/codesigning/cert` |
| Secret key | `thumbprint` |
| Cert thumbprint (POC self-signed) | `D359EC24DDD47A38AB5EB077685D42606616CCB9` |
| Admin token retrieval | HCP portal → vault-gusa-prod → Access Vault → Command-line (CLI) → Generate admin token |
| HCP Service Principal | `vault-gusa-admin` |
| HCP Client ID | `19b208a96a59cdb51e1de5dfacff3e11` |
| HCP Client Secret | `cd3b0bd780fcaae2b64d633fc4aa66e68195fe87c5ff41955fc7d53e9ba10f94` |
| HCP Org ID | `61402785-8e3b-4a17-b0d5-644b1eeace97` |

---

## GitHub Secrets

### Currently Set
| Secret | Value |
|---|---|
| `JFROG_URL` | `https://freenferal.jfrog.io` |
| `JFROG_REPO_KEY` | `dfcore-prod-local` |
| `AZURE_TENANT_ID` | `55f5d6da-59e4-4599-ba22-a97fc476f3aa` |
| `AZURE_SUBSCRIPTION_ID` | `e09a0f00-c31e-48df-a5f3-4bccf78cf898` |
| `DOMAIN_NAME` | `dayforceusa.local` |
| `APP_POOL_GMSA` | `dfGusaAppPool$` |
| `DEPLOY_PATH` | `F:\Dayforce\Site\prod` |
| `STAGING_PATH` | `C:\DfGusaStaging` |
| `APP_URL` | `http://www.dayforcenextgen.gov` |
| `VAULT_ADDR` | `https://vault-gusa-prod-public-vault-8632fb0b.fed357f8.z1.hashicorp.cloud:8200` |
| `VAULT_NAMESPACE` | `admin` |
| `VAULT_ROLE_ID` | `3a4ceeda-3d40-1b93-3a41-05ed5cbc8ab2` |
| `VAULT_SECRET_ID` | `a1c1547c-8ef3-8457-fe63-bfb0b4fc21aa` |

### Pending (add when infrastructure is ready)
| Secret | Value |
|---|---|
| `AZURE_CLIENT_ID` | TBD — federated credential for OIDC to JFrog + Azure |
| `LB_NAME` | `lb-gusa-prod-east-us` |
| `LB_BACKEND_POOL` | `be-gusa-appserver` |
| `LB_RESOURCE_GROUP` | `rg-gusa-prod-east-us` |
| `STATE_STORAGE_ACCOUNT` | `stgusastatetable` |
| `STATE_STORAGE_KEY` | TBD |
| `APP_SERVER_BASE_IMAGE` | TBD — base image resource ID for new-VM provisioning |
| `JFROG_ACCESS_TOKEN` | Remove once OIDC confirmed working |
