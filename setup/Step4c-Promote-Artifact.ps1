<#
.SYNOPSIS
    Promotes a signed artifact from dfcore-preprod-local to dfcore-prod-local
    and triggers the GUSA GitHub Actions deployment workflow.

.WHAT THIS DOES
    1. Uses jf rt copy to promote the artifact (preprod -> prod).
       This simulates what a release manager does to cross the GUSA boundary.
    2. Calls the GitHub repository_dispatch API to trigger the deployment workflow.
       In production, step 2 is handled automatically by a JFrog Webhook (see below).
       For the POC we do it here so you don't need the webhook configured yet.

.JFROG WEBHOOK (production setup - one-time, do when ready)
    Once configured, the webhook replaces step 2 entirely.
    Any jf rt copy to dfcore-prod-local fires the webhook automatically.

    JFrog UI: Administration > General > Webhooks > New Webhook
      Name   : github-gusa-deploy-trigger
      URL    : https://api.github.com/repos/spartnick-hub/dayforce-gusa-deployment/dispatches
      Events : Artifact > Artifact Was Copied
      Filter : dfcore-prod-local
      Headers:
        Authorization       : Bearer <github-pat>
        Accept              : application/vnd.github+json
        X-GitHub-Api-Version: 2022-11-28
        Content-Type        : application/json
      Body template:
        {
          "event_type": "artifact-promoted",
          "client_payload": {
            "artifact_path": "{{ index .data "targetPath" }}",
            "repo_key": "{{ index .data "targetRepoKey" }}"
          }
        }

    GitHub PAT: Settings > Developer settings > Personal access tokens (fine-grained)
      Repository : spartnick-hub/dayforce-gusa-deployment
      Permission : Actions (write)

.USAGE
    & "D:\Dayforce\repos\hcm\gusa-pipeline\setup\Step4c-Promote-Artifact.ps1" -Version 1.0.1

.PARAMETERS
    -SkipDispatch  Use this once the JFrog webhook is configured to avoid double-triggering.
#>

param(
    [string]$Version        = "1.0.1",
    [string]$SourceRepo     = "dfcore-preprod-local",
    [string]$TargetRepo     = "dfcore-prod-local",
    [string]$ArtifactFolder = "Dayforce",
    [string]$JfrogServerId  = "freenferal",
    [string]$GHRepo         = "spartnick-hub/dayforce-gusa-deployment",
    [switch]$SkipDispatch
)

$ErrorActionPreference = "Stop"

$artifactName = "DFCore-$Version.zip"
$sourcePath   = "$SourceRepo/$ArtifactFolder/$Version/$artifactName"
$targetPath   = "$TargetRepo/$ArtifactFolder/$Version/$artifactName"

Write-Host "=== Step 4c: Promote Artifact to Production ===" -ForegroundColor Cyan
Write-Host "From : $sourcePath"
Write-Host "To   : $targetPath"
Write-Host ""

# ==============================================================================
# 1. Promote: copy artifact from preprod -> prod
# ==============================================================================
Write-Host "Promoting artifact ..." -ForegroundColor Cyan

jf rt copy "$sourcePath" "$targetPath" --server-id $JfrogServerId --flat=true

if ($LASTEXITCODE -ne 0) {
    throw "JFrog copy failed. Verify DFCore-$Version.zip exists in $SourceRepo/Dayforce/$Version/."
}

Write-Host "Artifact promoted to $TargetRepo." -ForegroundColor Green
Write-Host ""

# ==============================================================================
# 2. Trigger GitHub deployment workflow via repository_dispatch.
#    Production: JFrog webhook does this automatically.
#    POC: we call the GitHub API directly using the gh CLI token.
# ==============================================================================
if (-not $SkipDispatch) {
    Write-Host "Triggering deployment workflow via repository_dispatch ..." -ForegroundColor Cyan

    $ghToken = gh auth token 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ghToken)) {
        throw "Not logged in to gh CLI. Run: gh auth login"
    }

    $headers = @{
        Authorization          = "Bearer $ghToken"
        Accept                 = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    $body = @{
        event_type     = "artifact-promoted"
        client_payload = @{
            artifact_path = "$ArtifactFolder/$Version/$artifactName"
            repo_key      = $TargetRepo
        }
    } | ConvertTo-Json -Depth 3

    Invoke-RestMethod `
        -Uri         "https://api.github.com/repos/$GHRepo/dispatches" `
        -Method      POST `
        -Headers     $headers `
        -Body        $body `
        -ContentType "application/json"

    Write-Host "Workflow triggered." -ForegroundColor Green
    Write-Host "Watch: https://github.com/$GHRepo/actions"
} else {
    Write-Host "SkipDispatch set - JFrog webhook will trigger the workflow." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Green
Write-Host "Artifact : $targetPath"
Write-Host "Trigger  : event_type=artifact-promoted, version=$Version"
