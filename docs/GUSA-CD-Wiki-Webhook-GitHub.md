# GUSA CD Pipeline — JFrog Webhook & GitHub Actions Wiki

**Audience:** Deployment Engineering team
**Covers:** How the JFrog-to-GitHub trigger chain works, how to manage it, how to debug it

---

## Table of Contents

1. [The Trigger Chain](#1-the-trigger-chain)
2. [JFrog Webhook — What It Is](#2-jfrog-webhook--what-it-is)
3. [JFrog Feed Promotion Flow](#3-jfrog-feed-promotion-flow)
4. [GitHub Workflow Architecture](#4-github-workflow-architecture)
5. [How the Workflow Is Triggered](#5-how-the-workflow-is-triggered)
6. [The Two Manual Gates](#6-the-two-manual-gates)
7. [What Runs on What Runner](#7-what-runs-on-what-runner)
8. [Authentication Chain](#8-authentication-chain)
9. [Managing the Webhook](#9-managing-the-webhook)
10. [Rotating the PAT](#10-rotating-the-pat)
11. [Testing the Trigger Without a Real Promotion](#11-testing-the-trigger-without-a-real-promotion)
12. [Debugging Checklist](#12-debugging-checklist)

---

## 1. The Trigger Chain

```
RELEASE MANAGER ACTION
  JFrog UI -> Packages -> dfcore-preprod-feed
  Drag artifact to dfcore-prod-feed
           |
           | JFrog Event Service fires "artifact copied" event
           | webhook key: github-gusa-dispatch
           v
JFROG WEBHOOK
  POST https://api.github.com/repos/spartnick-hub/dayforce-gusa-deployment/dispatches
  Headers:
    Authorization: Bearer {{ .secrets.ghpat }}   <- encrypted in JFrog
    Accept: application/vnd.github.v3+json
    Content-Type: application/json
  Body (JFrog template rendered at fire time):
    {
      "event_type": "artifact-promoted",
      "client_payload": {
        "artifact_path": "Dayforce/1.0.1/DFCore-1.0.1.zip",
        "repo_key": "dfcore-prod-feed"
      }
    }
           |
           v
GITHUB ACTIONS
  deploy-gusa.yml receives repository_dispatch
  event_type == "artifact-promoted"
  resolve-version job:
    version = "1.0.1"   (extracted from artifact_path, field [2] split by /)
    jfrog_repo = "dfcore-prod-feed"
  deploy job calls _core-deploy.yml reusable workflow
```

---

## 2. JFrog Webhook — What It Is

The webhook is a **JFrog Event Service subscription** (not an Artifactory webhook — different API base path).

| Property | Value |
|---|---|
| Webhook key | `github-gusa-dispatch` |
| JFrog API path | `https://freenferal.jfrog.io/event/api/v1/subscriptions/github-gusa-dispatch` |
| Trigger domain | `artifact` |
| Trigger event | `copied` |
| Source feed | `dfcore-preprod-feed` |
| Target (in payload) | `dfcore-prod-feed` (from `data.target_repo_path`) |
| GitHub PAT storage | Encrypted JFrog secret named `ghpat` — never transmitted in plaintext |
| Handler type | `custom-webhook` |

**Important:** The `copied` event fires on the **source** feed, not the destination. We watch `dfcore-preprod-feed`. When an artifact is dragged to `dfcore-prod-feed`, JFrog fires the event on preprod, and `data.target_repo_path` tells us where it went.

### What JFrog sends GitHub

```json
{
  "event_type": "artifact-promoted",
  "client_payload": {
    "artifact_path": "Dayforce/1.0.1/DFCore-1.0.1.zip",
    "repo_key": "dfcore-prod-feed"
  }
}
```

- **`artifact_path`**: path within the source feed (`{{ .data.path }}`)
- **`repo_key`**: the destination feed (`{{ .data.target_repo_path }}`) — this is what the pipeline downloads from

---

## 3. JFrog Feed Promotion Flow

```
CI Build
   |
   | jf rt upload DFCore-1.0.0.zip dfcore-dev-feed/Dayforce/1.0.0/
   v
dfcore-dev-feed
   Unsigned artifact: Dayforce/1.0.0/DFCore-1.0.0.zip
   Used for: Milestone 1 fail-fast test (unsigned -> code signing fails)
   |
   | Code signing pipeline (separate CI step)
   | Signs DLLs inside web.rar with cert D359EC24...
   | jf rt copy dfcore-dev-feed -> dfcore-preprod-feed
   v
dfcore-preprod-feed
   Signed artifact: Dayforce/1.0.1/DFCore-1.0.1.zip
   Used for: QA validation, signing verification
   |
   | RELEASE MANAGER: drags to dfcore-prod-feed in JFrog UI
   | (or: jf rt copy dfcore-preprod-feed/... dfcore-prod-feed/)
   v
dfcore-prod-feed
   Promoted artifact: Dayforce/1.0.1/DFCore-1.0.1.zip
   JFrog webhook fires -> GitHub Actions starts
   |
   v
DEPLOYMENT PIPELINE RUNS
```

---

## 4. GitHub Workflow Architecture

```
spartnick-hub/dayforce-gusa-deployment
|
+-- .github/
|   |
|   +-- actions/
|   |   +-- verify-codesign/action.yml    <- Composite action
|   |       Vault CLI login
|   |       Get expected thumbprint from Vault
|   |       signtool.exe verify extracted DLLs
|   |       FAIL FAST if any DLL unsigned or wrong cert
|   |
|   +-- workflows/
|       +-- deploy-gusa.yml               <- CALLER (thin, per-environment)
|       |   Listens: repository_dispatch, schedule, workflow_dispatch
|       |   resolve-version job
|       |   Calls _core-deploy.yml with production environment
|       |
|       +-- _core-deploy.yml              <- REUSABLE (all logic here)
|           on: workflow_call only
|           Jobs: pre-deploy-validation, approval-gate,
|                 deploy-web, deploy-bje, deploy-db,
|                 smoke-test, finalize, rollback
|
+-- scripts/
|   +-- common/   Verify-CodeSigning.ps1
|   +-- web/      Provision-AppServerVM.ps1, Bootstrap-NewVM.ps1,
|   |             Deploy-WebArtifacts.ps1, Set-LoadBalancerBackend.ps1,
|   |             Start-AppPools.ps1, Stop-AppPools.ps1,
|   |             Invoke-WebSmokeTest.ps1
|   +-- bje/      Provision-BJEServerVM.ps1, Bootstrap-BJENewVM.ps1,
|   |             Deploy-BJEArtifacts.ps1
|   +-- db/       Backup-Database.ps1, Deploy-Database.ps1,
|   |             Rollback-Database.ps1
|   +-- runner/   Bootstrap-GHRunner.ps1
|
+-- prod/
    +-- shared-config.yaml
    +-- us/eastus/wwwprod/
        +-- siteconfig.yaml        <- Deployer.exe variables for this pod
        +-- iss-metadata.yaml      <- Base image IDs for this pod's VMs
```

### Caller vs Reusable Pattern

`deploy-gusa.yml` is deliberately thin — it only resolves the version and passes environment-specific secrets down to `_core-deploy.yml`. This means:

- **To deploy to a new environment**: write a 10-line caller, no changes to `_core-deploy.yml`
- **To fix pipeline logic**: edit only `_core-deploy.yml`, all environments benefit

---

## 5. How the Workflow Is Triggered

`deploy-gusa.yml` responds to three trigger types:

| Trigger | When | `version` | `jfrog_repo` |
|---|---|---|---|
| `repository_dispatch` (JFrog webhook) | Release Manager promotes artifact | Extracted from `artifact_path` | `dfcore-prod-feed` (from payload) |
| `schedule` (cron) | Every Monday 6pm EST (`0 23 * * 1`) | Blank -> resolves latest from JFrog | Default (`vars.JFROG_PROD_REPO`) |
| `workflow_dispatch` (manual) | Deployment Engineer triggers manually | Entered at trigger time (blank = latest) | Entered at trigger time |

### Version Extraction Logic

```bash
artifact_path="Dayforce/1.0.1/DFCore-1.0.1.zip"
version=$(echo "$artifact_path" | awk -F'/' '{print $2}')
# version = "1.0.1"
```

The JFrog artifact path format is: `Dayforce/{version}/DFCore-{version}.zip`

---

## 6. The Two Manual Gates

The pipeline has exactly two points where a human must approve before proceeding:

### Gate 1 — Pre-Deployment (environment: `production`)

```
Code signing PASSES
       |
       | Pipeline pauses here
       v
  [GitHub: production environment required reviewers]
  Reviewer sees: version, artifact from feed, LB state (which VMs are live)
  APPROVE -> New VMs provisioned, artifact deployed to Green
  REJECT  -> Pipeline ends, nothing deployed, Blue still live
```

**Configure:** Settings -> Environments -> production -> Required reviewers

### Gate 2 — Swap (environment: `production-swap`)

```
Smoke test PASSES against Green VM (direct IP, bypassing LB)
Blue VM still handling all live traffic
       |
       | Pipeline pauses here
       v
  [GitHub: production-swap environment required reviewers]
  Reviewer sees: smoke test results, Green VM IP, version deployed
  APPROVE -> LB swap (Blue removed, Green takes over), Blue VM deleted
  REJECT  -> Leave Green running for investigation (or trigger rollback manually)
```

**Configure:** Settings -> Environments -> production-swap -> Required reviewers

> **Note on GitHub Plan:** Required reviewers on private repos requires GitHub Team plan. GitHub Pro is insufficient. Until Team plan: environments exist but gate auto-approves.

---

## 7. What Runs on What Runner

| Job | Runner | Why |
|---|---|---|
| `resolve-version` | `ubuntu-latest` (GitHub-hosted) | Bash string manipulation only, no Azure/Windows tools needed |
| All other jobs | Self-hosted VMSS (`vmss-gusa-ghrunner`) | Needs Windows, signtool.exe, vault.exe, az CLI, domain-joined for gMSA |

### Self-Hosted Runner Setup

Runners are ephemeral VMSS instances (`vmss-gusa-ghrunner`):

- Uniform orchestration mode (required for GitHub runner VMSS)
- Windows Server 2022
- Domain-joined to `dayforceusa.local` (enables gMSA usage)
- gMSA `ghrunner$` — used by the runner service itself
- `Bootstrap-GHRunner.ps1` runs on every new instance:
  - Installs vault CLI, az CLI, 7-Zip, signtool
  - Fetches GitHub App private key from Vault
  - Generates runner registration token via GitHub App
  - Registers runner with labels `self-hosted,Windows,gusa-runner`
  - Installs runner as Windows service under `ghrunner$` gMSA

---

## 8. Authentication Chain

```
GitHub Actions Runner
   |
   | Azure OIDC (no client secrets)
   | App Registration: gusa-github-actions-oidc
   | Client ID: b581b048-a3cd-4c31-911c-5351ce7de673
   v
Azure (subscription, resource group, VNet, LB, Blob, Compute Gallery)

GitHub Actions Runner
   |
   | JFrog Access Token (JFROG_ACCESS_TOKEN secret)
   v
JFrog Artifactory (download artifact from dfcore-prod-feed)

GitHub Actions Runner
   |
   | HCP Vault AppRole (HC_VAULT_ROLE_ID + HC_VAULT_SECRET_ID)
   | via vault CLI (vault.exe)
   v
HCP Vault -> returns code signing cert thumbprint
   |
   v
signtool.exe verifies DLLs against thumbprint

JFrog Webhook -> GitHub API
   |
   | GitHub Fine-Grained PAT (stored encrypted in JFrog as secret 'ghpat')
   | PAT: jfrog-gusa-dispatch (on account spartnick-hub)
   | Scope: Contents Read+Write on dayforce-gusa-deployment repo
   v
GitHub repository_dispatch
```

---

## 9. Managing the Webhook

### View current webhook configuration

```powershell
$jfToken = '<jfrog-admin-access-token>'
Invoke-RestMethod `
    -Uri     'https://freenferal.jfrog.io/event/api/v1/subscriptions/github-gusa-dispatch' `
    -Method  GET `
    -Headers @{ Authorization = "Bearer $jfToken" } | ConvertTo-Json -Depth 10
```

### Enable or disable the webhook

```powershell
$jfToken = '<jfrog-admin-access-token>'
$body = '{"enabled": false}'
[System.IO.File]::WriteAllText('C:\Temp\patch.json', $body, (New-Object System.Text.UTF8Encoding $false))
Invoke-RestMethod `
    -Uri         'https://freenferal.jfrog.io/event/api/v1/subscriptions/github-gusa-dispatch' `
    -Method      PUT `
    -Headers     @{ Authorization = "Bearer $jfToken" } `
    -InFile      'C:\Temp\patch.json' `
    -ContentType 'application/json'
```

### Delete the webhook

```powershell
$jfToken = '<jfrog-admin-access-token>'
Invoke-RestMethod `
    -Uri     'https://freenferal.jfrog.io/event/api/v1/subscriptions/github-gusa-dispatch' `
    -Method  DELETE `
    -Headers @{ Authorization = "Bearer $jfToken" }
```

### Recreate the webhook (if ever needed)

Run `Step7-Create-JFrog-Webhook.ps1` from `D:\Dayforce\repos\hcm\gusa-pipeline\setup\`:

```powershell
& "D:\Dayforce\repos\hcm\gusa-pipeline\setup\Step7-Create-JFrog-Webhook.ps1" `
    -JFrogUrl   https://freenferal.jfrog.io `
    -JFrogToken eyJ... `
    -SourceRepo dfcore-preprod-feed `
    -GitHubRepo spartnick-hub/dayforce-gusa-deployment `
    -GitHubPat  github_pat_...
```

The script is idempotent — it updates if the webhook already exists.

---

## 10. Rotating the PAT

The GitHub PAT stored in the JFrog webhook (`ghpat` secret) will expire based on how it was configured. Rotate it without recreating the webhook:

```powershell
$jfToken = '<jfrog-admin-access-token>'
$newPat  = '<new-github-fine-grained-pat>'

Invoke-RestMethod `
    -Uri     'https://freenferal.jfrog.io/event/api/v1/subscriptions/github-gusa-dispatch/secrets/ghpat' `
    -Method  PUT `
    -Headers @{ Authorization = "Bearer $jfToken"; 'Content-Type' = 'text/plain' } `
    -Body    $newPat
```

**New PAT requirements:**
- Fine-grained PAT on account `spartnick-hub`
- Repository access: `spartnick-hub/dayforce-gusa-deployment`
- Permission: Contents — Read and Write
- Create at: https://github.com/settings/personal-access-tokens/new

After creating, update the `JFROG_DISPATCH_PAT` note in your password manager, then run the command above.

---

## 11. Testing the Trigger Without a Real Promotion

### Option A — Manual workflow dispatch (simplest)

Go to: https://github.com/spartnick-hub/dayforce-gusa-deployment/actions
Select `deploy-gusa` -> Run workflow
Set `jfrog_repo` = `dfcore-dev-feed` (will trigger fail-fast on unsigned artifact)

### Option B — Simulate the webhook payload via PowerShell

```powershell
$ghPat = '<your-github-pat>'

Invoke-RestMethod `
    -Uri     'https://api.github.com/repos/spartnick-hub/dayforce-gusa-deployment/dispatches' `
    -Method  POST `
    -Headers @{
        Authorization = "Bearer $ghPat"
        Accept        = 'application/vnd.github.v3+json'
        'Content-Type' = 'application/json'
    } `
    -Body    '{"event_type":"artifact-promoted","client_payload":{"artifact_path":"Dayforce/1.0.0/DFCore-1.0.0.zip","repo_key":"dfcore-dev-feed"}}'
```

This fires the workflow exactly as if JFrog triggered it. Using `dfcore-dev-feed` as `repo_key` with the unsigned artifact triggers the fail-fast code signing failure (Milestone 1 test).

### Option C — Promote a real artifact in JFrog

```powershell
# Using JFrog CLI
jf rt copy dfcore-preprod-feed/Dayforce/1.0.1/DFCore-1.0.1.zip dfcore-prod-feed/ --server-id freenferal
```

This triggers the real webhook with a real signed artifact.

---

## 12. Debugging Checklist

### Webhook fired but workflow did not start

1. Check JFrog webhook execution log: JFrog UI -> Administration -> Webhooks -> `github-gusa-dispatch` -> Executions tab
2. Check GitHub dispatches received: https://github.com/spartnick-hub/dayforce-gusa-deployment/actions (filter by `repository_dispatch`)
3. Verify PAT is not expired: try a manual dispatch with the PAT using Option B above
4. Verify the artifact path format is `Dayforce/{version}/DFCore-{version}.zip` — version extraction depends on this

### Workflow started but runner never picked up the job

1. Check VMSS instance count: `az vmss list-instances -g rg-gusa-prod-east-us -n vmss-gusa-ghrunner`
2. Check runner registration: https://github.com/spartnick-hub/dayforce-gusa-deployment/settings/actions/runners
3. If runners show offline: check VMSS Custom Script Extension logs inside an instance via Bastion
4. Verify `RUNNER_LABELS` var matches the labels runners registered with

### Code signing step fails on a signed artifact

1. Check Vault is reachable: `vault.exe login -method=approle role_id=... secret_id=...` on a runner
2. Check thumbprint in Vault: `vault.exe kv get secret/codesigning/cert` -> field `thumbprint`
3. Expected: `D359EC24DDD47A38AB5EB077685D42606616CCB9`
4. Run `signtool.exe verify /pa /v <dll>` manually on the extracted DLL

### Job fails at Azure login (OIDC)

1. Verify `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` are set in GitHub environment secrets
2. Check federated credential on App Registration `gusa-github-actions-oidc` in Azure Portal
3. Federated credential subject must match: `repo:spartnick-hub/dayforce-gusa-deployment:environment:production`
