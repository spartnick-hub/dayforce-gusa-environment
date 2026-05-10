# GUSA CD Pipeline — End-to-End Wiki

**Product:** Dayforce (GUSA — Government USA)
**Stack:** .NET Framework 4.7.2 web monolith
**Pattern:** New-VM Blue/Green with Azure Load Balancer
**Scope:** Everything after CI — artifact promotion through production traffic cutover

---

## Table of Contents

1. [Organizational Roles](#1-organizational-roles)
2. [Architecture Overview](#2-architecture-overview)
3. [Infrastructure Inventory](#3-infrastructure-inventory)
4. [Terminology](#4-terminology)
5. [Deployment Flow — Step by Step](#5-deployment-flow--step-by-step)
6. [Blue/Green Lifecycle](#6-bluegreen-lifecycle)
7. [Manual Gates](#7-manual-gates)
8. [Rollback](#8-rollback)
9. [Variable and Secret Reference](#9-variable-and-secret-reference)
10. [Onboarding a New Environment](#10-onboarding-a-new-environment)
11. [Rotating Secrets](#11-rotating-secrets)
12. [Cost Cleanup](#12-cost-cleanup)

---

## 1. Organizational Roles

| Team | Role in This Pipeline |
|---|---|
| **Release Management** | Promotes artifact from `dfcore-preprod-feed` to `dfcore-prod-feed` via JFrog UI drag-and-drop. This single action triggers the entire CD pipeline automatically. |
| **Deployment Engineering** | Owns and maintains this pipeline. Approves the pre-deployment gate and the production swap gate. |

Release Management has no CLI access or GitHub access. Their only action is the JFrog UI promotion. The pipeline does everything else.

---

## 2. Architecture Overview

```
JFrog Artifactory (freenferal.jfrog.io)
  dfcore-dev-feed        <- CI uploads unsigned artifacts here
  dfcore-preprod-feed    <- Signing pipeline promotes here (signed)
  dfcore-prod-feed       <- Release Manager promotes here -> TRIGGERS DEPLOY

GitHub Actions (spartnick-hub/dayforce-gusa-deployment)
  deploy-gusa.yml        <- Caller workflow (thin, per-environment)
  _core-deploy.yml       <- Reusable workflow (all logic lives here)
  verify-codesign/       <- Composite action (Vault + signtool FAIL FAST)

Azure (subscription: e09a0f00-c31e-48df-a5f3-4bccf78cf898)
  Resource Group: rg-gusa-prod-east-us (East US)
  VNet: vnet-gusa-prod-east-us / snet-gusa-prod (10.10.1.0/24)
  Load Balancer: lb-gusa-prod-east-us
    Backend Pool: be-gusa-appserver  <- SOURCE OF TRUTH for live VM
  Compute Gallery: galGusaProd
    img-gusa-appserver               <- Base image for new app server VMs
    img-gusa-bjeserver               <- Base image for new BJE server VMs
  VMSS: vmss-gusa-ghrunner           <- GitHub Actions self-hosted runners
  Entra DS: dayforceusa.local        <- DCs: 10.10.2.4, 10.10.2.5
  Storage: stgusablobeastus/deployments <- Artifact + script staging

HCP Vault (vault-gusa-prod)
  secret/codesigning/cert -> thumbprint  <- Expected signing certificate
  secret/github/app       -> app_id, private_key
```

---

## 3. Infrastructure Inventory

| Resource | Name | Notes |
|---|---|---|
| Resource Group | `rg-gusa-prod-east-us` | All GUSA resources |
| VNet | `vnet-gusa-prod-east-us` | |
| App Subnet | `snet-gusa-prod` | `10.10.1.0/24` |
| DS Subnet | `snet-gusa-ds` | `10.10.2.0/24` |
| Load Balancer | `lb-gusa-prod-east-us` | Standard SKU, internal |
| LB Backend Pool | `be-gusa-appserver` | Live VMs registered here |
| Bastion | `bastion-gusa-prod` | Admin access only — delete when not debugging |
| NAT Gateway | `nat-gusa-prod` | Outbound internet for VMs |
| Storage Account | `stgusablobeastus` | Container: `deployments` |
| Compute Gallery | `galGusaProd` | Image definitions inside |
| App Server Image | `img-gusa-appserver` | Base image for web tier VMs |
| BJE Server Image | `img-gusa-bjeserver` | Base image for BJE tier VMs |
| Runner VMSS | `vmss-gusa-ghrunner` | Uniform orchestration, ephemeral |
| Entra DS | `dayforceusa.local` | DCs: `10.10.2.4`, `10.10.2.5` |
| App Server VM | `vm-gusa-appserver-01` | Sysprepped and captured as base image |

---

## 4. Terminology

| Term | Meaning |
|---|---|
| **Feed** | JFrog Artifactory repository. Three feeds exist: `dev`, `preprod`, `prod`. |
| **Blue VM** | The currently live app server VM handling production traffic |
| **Green VM** | The newly provisioned VM for the incoming deployment |
| **LB Swap** | Removing Blue from the LB backend pool and the Green VM takes over — this is the cutover moment |
| **Fail Fast** | Code signing runs before any VM is provisioned. Unsigned = immediate abort, zero cost, zero risk |
| **Pod** | A deployment target folder in the repo (`prod/us/eastus/wwwprod`) containing `siteconfig.yaml` and `iss-metadata.yaml` |
| **gMSA** | Group Managed Service Account — passwordless Windows service identity used by IIS app pools and the GitHub runner |

---

## 5. Deployment Flow — Step by Step

```
TRIGGER
  Release Manager drags artifact in JFrog UI
  dfcore-preprod-feed -> dfcore-prod-feed
         |
         | JFrog "artifact copied" webhook
         v
  GitHub: deploy-gusa.yml starts
  resolve-version job extracts version from artifact path
         |
         v
JOB 1: pre-deploy-validation  [self-hosted runner]
  1. Azure OIDC login (no passwords)
  2. JFrog CLI: resolve latest version OR use webhook payload version
  3. Query LB backend pool -> identify current live (Blue) VMs
  4. Download artifact zip from dfcore-prod-feed
  5. Extract sample DLLs from web.rar
  6. HCP Vault AppRole login -> get expected cert thumbprint
  7. signtool.exe verify each DLL
     FAIL -> pipeline aborts HERE. No VMs touched. Zero cost.
     PASS -> continue
  8. Upload artifact + scripts to Azure Blob (staging for VM bootstrap)
         |
         v
JOB 2: approval-gate  [manual gate via GitHub environment: production]
  Human reviews: "Is this the right version? Proceed?"
  APPROVE -> continue
  REJECT  -> pipeline ends, nothing deployed
         |
         v
JOB 3a: deploy-web  ]  PARALLEL
JOB 3b: deploy-bje  ]
  For each:
  1. Provision brand-new VM from base image (Green VM)
     VM name: vm-gusa-appserver-{timestamp} or vm-gusa-bjeserver-{timestamp}
  2. Run-command: Bootstrap-NewVM.ps1 inside the VM
     - Downloads artifact zip from Blob
     - Downloads deploy scripts from Blob
     - Runs Deploy-WebArtifacts.ps1 (extracts web.rar, runs Deployer.exe)
     - Starts IIS app pools under dfGusaAppPool$ gMSA
  3. Add new VM to LB backend pool (alongside Blue — both receive traffic momentarily)
     Wait — no! Green is NOT added to LB yet. It is smoke-tested via direct private IP first.
         |
         v
JOB 4: deploy-db  (runs after deploy-web AND deploy-bje both succeed)
  1. Backup-Database.ps1 -> snapshot Control DB
  2. Deploy-Database.ps1 -> run migration via Deployer.exe
         |
         v
JOB 5: smoke-test
  Invoke-WebSmokeTest.ps1
  Hits Green VM via DIRECT PRIVATE IP (bypasses LB entirely)
  Blue VM is untouched and still serving ALL live traffic
  Checks: HTTP 200, version header matches expected build version
  FAIL -> trigger rollback job
  PASS -> continue
         |
         v
JOB 6a: finalize  [GATE: GitHub environment: production-swap]
  Human reviews smoke test results: "Green looks good, swap it?"
  APPROVE ->
    1. Remove Blue VM from LB backend pool (CUTOVER - takes ~2 seconds)
       All traffic now goes to Green VM
    2. Delete Blue web VM (--no-wait, fire and forget)
    3. Delete Blue BJE VM (--no-wait)
  REJECT -> manually trigger rollback or leave Green running for more investigation

JOB 6b: rollback  (if smoke-test failed)
  1. Remove Green VM from LB backend pool (if it was added)
  2. Rollback-Database.ps1 -> restore DB snapshot
  3. Delete Green web VM
  4. Delete Green BJE VM
  Blue VM never stopped. Zero downtime.
```

---

## 6. Blue/Green Lifecycle

```
BEFORE DEPLOYMENT
+------------------+          +------------------+
| Azure LB         |          | Blue VM          |
| be-gusa-appserver|--------->| vm-appserver-old |  <-- all live traffic
+------------------+          | 10.10.1.x        |
                              +------------------+

DURING DEPLOYMENT (after Jobs 3-5, before Job 6a gate)
+------------------+          +------------------+
| Azure LB         |          | Blue VM          |
| be-gusa-appserver|--------->| vm-appserver-old |  <-- still ALL live traffic
+------------------+          | 10.10.1.x        |
                              +------------------+

                              +------------------+
              direct IP  ---->| Green VM         |  <-- smoke test ONLY
                              | vm-appserver-new |
                              | 10.10.1.y        |
                              +------------------+

AFTER JOB 6a GATE APPROVED (LB swap)
+------------------+          +------------------+
| Azure LB         |          | Green VM         |
| be-gusa-appserver|--------->| vm-appserver-new |  <-- all live traffic
+------------------+          | 10.10.1.y        |
                              +------------------+

                              Blue VM deleted (--no-wait)
```

**Key property:** Blue VM is never stopped or removed from the LB until the human approves the swap. Rollback at any point before the gate = zero downtime.

---

## 7. Manual Gates

| Gate | GitHub Environment | When | Who Approves |
|---|---|---|---|
| **Pre-deployment** | `production` | After code signing, before any VM provisioned | Deployment Engineering |
| **Swap** | `production-swap` | After smoke test passes, before LB cutover | Deployment Engineering |

To configure approvers: **Settings → Environments → [env name] → Required reviewers**

> Note: Required reviewers on private repos need GitHub Team plan or higher. GitHub Pro is insufficient.

---

## 8. Rollback

| Scenario | What Happens |
|---|---|
| Code signing fails | Pipeline aborts. No VMs provisioned. No cost. |
| Approval rejected | Pipeline ends. No VMs provisioned. |
| Deploy fails (web or BJE) | `rollback` job fires automatically. Green VM deleted. Blue still serving. |
| Smoke test fails | `rollback` job fires automatically. Green VM deleted. DB snapshot restored. Blue still serving. |
| Post-swap issue | Requires manual intervention. Green is now live, Blue is deleted. Trigger a new deployment with the previous version. |

---

## 9. Variable and Secret Reference

All configuration lives in **GitHub Environment** vars and secrets. Nothing is hardcoded in workflows or scripts.

### GitHub Secrets (sensitive values)

| Secret | Example Value | Notes |
|---|---|---|
| `AZURE_CLIENT_ID` | `b581b048-...` | OIDC App Registration client ID |
| `AZURE_TENANT_ID` | `55f5d6da-...` | Azure AD tenant |
| `AZURE_SUBSCRIPTION_ID` | `e09a0f00-...` | Azure subscription |
| `JFROG_URL` | `https://freenferal.jfrog.io` | JFrog platform URL |
| `JFROG_ACCESS_TOKEN` | `eyJ...` | JFrog access token |
| `HC_VAULT_ADDR` | `https://vault-gusa-prod-...` | HCP Vault URL |
| `HC_VAULT_NAMESPACE` | `admin` | Vault namespace |
| `HC_VAULT_ROLE_ID` | `3a4ceeda-...` | AppRole Role ID |
| `HC_VAULT_SECRET_ID` | `a1c1547c-...` | AppRole Secret ID (rotatable) |
| `LB_NAME` | `lb-gusa-prod-east-us` | Azure Load Balancer name |
| `LB_BACKEND_POOL` | `be-gusa-appserver` | LB backend pool name |
| `APP_POOL_GMSA` | `dayforceusa\dfGusaAppPool$` | IIS app pool gMSA |
| `APP_SERVER_BASE_IMAGE` | fallback only | Overridden by `iss-metadata.yaml` |
| `TEAMS_WEBHOOK_URL` | optional | Teams alerting |

### GitHub Variables (non-sensitive)

| Variable | Example Value | Notes |
|---|---|---|
| `RESOURCE_GROUP` | `rg-gusa-prod-east-us` | Azure resource group |
| `POD_PATH` | `prod/us/eastus/wwwprod` | In-repo pod folder |
| `RUNNER_LABELS` | `["self-hosted","Windows","gusa-runner"]` | JSON array |
| `JFROG_PROD_REPO` | `dfcore-prod-feed` | Default feed for deployment |

### Parameterization — Items Still to Variablize (Next Session)

These values are partially hardcoded in setup scripts and should be moved to variables for full reuse:

| Item | Current State | Target |
|---|---|---|
| GitHub org name | `spartnick-hub` hardcoded in some Step scripts | `GH_ORG` variable |
| GitHub repo name | `dayforce-gusa-deployment` in Step scripts | `GH_REPO` variable |
| JFrog org/platform URL | `freenferal.jfrog.io` in Step scripts | `JFROG_ORG` variable |
| JFrog feed names | `dfcore-dev-local` etc. | Rename to `dfcore-dev-feed` etc. and variablize |
| Azure resource names | Mostly variablized via GitHub vars, some Step script defaults remain | Audit Step1-7 scripts |

---

## 10. Onboarding a New Environment

The `_core-deploy.yml` reusable workflow is environment-agnostic. To deploy to a new environment (e.g. staging, another region):

1. Create a GitHub environment (e.g. `staging`)
2. Set all vars and secrets for that environment
3. Create `prod/us/eastus/staging-pod/siteconfig.yaml` and `iss-metadata.yaml`
4. Write a 10-line caller workflow (copy `deploy-gusa.yml`, change `environment: production` to `environment: staging`)
5. Done. No changes to `_core-deploy.yml` or any scripts.

---

## 11. Rotating Secrets

### JFrog Webhook PAT (GitHub PAT stored in JFrog)

When your GitHub PAT expires, rotate it without recreating the webhook:

```powershell
$jfToken = '<jfrog-admin-access-token>'
$newPat  = '<new-github-pat>'

Invoke-RestMethod `
    -Uri     'https://freenferal.jfrog.io/event/api/v1/subscriptions/github-gusa-dispatch/secrets/ghpat' `
    -Method  PUT `
    -Headers @{ Authorization = "Bearer $jfToken"; 'Content-Type' = 'text/plain' } `
    -Body    $newPat
```

### HCP Vault AppRole Secret ID

```bash
vault write -f auth/approle/role/gusa-deploy/secret-id
# Update HC_VAULT_SECRET_ID in GitHub environment secrets
```

### JFrog Access Token

Generate a new one in JFrog UI: **Administration → User Management → Access Tokens → Generate Token**
Update `JFROG_ACCESS_TOKEN` GitHub secret and the JFrog webhook token if used by Step scripts.

---

## 12. Cost Cleanup

**Run this when not actively using the pipeline to stop billing.**

### Highest-cost items first

| Resource | Monthly Cost | How to Stop |
|---|---|---|
| **Entra Domain Services** | ~$230/month | `az ds domain-service delete -g rg-gusa-prod-east-us -n dayforceusa.local` — **WARNING: deletes all gMSA accounts** |
| **Azure Bastion** | ~$140/month | `az network bastion delete -g rg-gusa-prod-east-us -n bastion-gusa-prod` |
| **Standard Load Balancer** | ~$18/month + data | Can't pause; delete if no traffic |
| **NAT Gateway** | ~$32/month | `az network nat gateway delete -g rg-gusa-prod-east-us -n nat-gusa-prod` |
| **VMSS Runner** | Per-instance | `az vmss scale -g rg-gusa-prod-east-us -n vmss-gusa-ghrunner --new-capacity 0` |
| **VMs** | Per-hour (compute) | `az vm deallocate -g rg-gusa-prod-east-us -n <vm-name>` |
| **Storage** | ~$2-5/month | Leave running (cheap, pipeline depends on it) |
| **Compute Gallery** | ~$1-3/month | Leave running (cheap, needed for deployments) |

### Quick suspend script (keeps infrastructure, stops active billing)

```powershell
$rg = 'rg-gusa-prod-east-us'

az vmss scale -g $rg -n vmss-gusa-ghrunner --new-capacity 0
az network bastion delete -g $rg -n bastion-gusa-prod --yes --no-wait
Write-Host "Bastion deleted (no-wait). VMSS scaled to 0."
Write-Host "Remaining: NAT Gateway, LB, Entra DS, Storage — delete manually if pausing for weeks."
Write-Host "Entra DS is $230/month — delete with: az ds domain-service delete -g $rg -n dayforceusa.local"
```

### To resume after suspend

1. Scale VMSS back up: `az vmss scale -g rg-gusa-prod-east-us -n vmss-gusa-ghrunner --new-capacity 2`
2. Recreate Bastion if deleted: Run `Step2b` equivalent from setup scripts
3. If Entra DS was deleted: must recreate from scratch (Step3 in setup), re-create gMSA accounts, re-domain-join all VMs
