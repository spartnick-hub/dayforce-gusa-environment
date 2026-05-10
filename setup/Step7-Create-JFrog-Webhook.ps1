<#
.SYNOPSIS
    Creates or updates the JFrog custom webhook that triggers the GUSA CD pipeline
    whenever an artifact is promoted (copied) from preprod-feed to prod-feed.

.MODES
    --FunctionUrl (recommended for production)
        JFrog calls an Azure Function relay. The function generates a fresh GitHub App
        installation token on each invocation — no static PAT stored anywhere.
        Run Deploy-GitHubRelayFunction.ps1 first to get the FunctionUrl.

    --GitHubPat (POC / fallback)
        JFrog calls the GitHub dispatch API directly using a long-lived PAT stored
        encrypted in JFrog. Requires annual rotation via rotate-webhook-pat.yml workflow.

.HOW THE TRIGGER CHAIN WORKS
    1. CI build uploads unsigned artifact to dfcore-dev-feed
    2. Signing pipeline signs and promotes to dfcore-preprod-feed
    3. Release Manager drags artifact in JFrog UI to dfcore-prod-feed
    4. JFrog fires this webhook (artifact copied FROM dfcore-preprod-feed)
       data.path             = artifact path within the feed
       data.target_repo_path = dfcore-prod-feed (destination)
    5a. (FunctionUrl mode) Azure Function receives POST, generates GitHub App token, dispatches
    5b. (GitHubPat mode)   JFrog calls GitHub dispatch API directly with PAT
    6. deploy-gusa.yml starts with event_type=artifact-promoted

.USAGE
    # Production (Azure Function relay — no static PAT):
    & ".\Step7-Create-JFrog-Webhook.ps1" `
        -FunctionUrl "https://func-gusa-github-relay.azurewebsites.net/api/GusaGitHubRelay?code=<key>"

    # POC / fallback (direct PAT):
    & ".\Step7-Create-JFrog-Webhook.ps1" `
        -GitHubPat "github_pat_xxxxxxxxxxxx"

    # Fully explicit:
    & ".\Step7-Create-JFrog-Webhook.ps1" `
        -JFrogUrl   https://freenferal.jfrog.io `
        -JFrogToken eyJ... `
        -SourceRepo dfcore-preprod-feed `
        -GitHubRepo spartnick-hub/dayforce-gusa-deployment `
        -FunctionUrl "https://func-gusa-github-relay.azurewebsites.net/api/GusaGitHubRelay?code=<key>"

.TO DELETE THE WEBHOOK
    $token = '<jfrog-access-token>'
    Invoke-RestMethod -Uri 'https://freenferal.jfrog.io/event/api/v1/subscriptions/github-gusa-dispatch' `
        -Method DELETE -Headers @{ Authorization = "Bearer $token" }
#>

param(
    [string]$JFrogUrl    = 'https://freenferal.jfrog.io',
    [string]$JFrogToken  = '',
    [string]$SourceRepo  = 'dfcore-preprod-feed',
    [string]$GitHubRepo  = 'spartnick-hub/dayforce-gusa-deployment',
    [string]$WebhookKey  = 'github-gusa-dispatch',

    [string]$FunctionUrl = '',

    [string]$GitHubPat   = ''
)

$ErrorActionPreference = 'Stop'

Write-Host '=== Step 7: Create JFrog Webhook ===' -ForegroundColor Cyan
Write-Host "JFrog URL   : $JFrogUrl"
Write-Host "Source feed : $SourceRepo  (event fires when artifact is COPIED FROM this feed)"
Write-Host "GitHub repo : $GitHubRepo"
Write-Host "Webhook key : $WebhookKey"
Write-Host ''

if ([string]::IsNullOrWhiteSpace($FunctionUrl) -and [string]::IsNullOrWhiteSpace($GitHubPat)) {
    Write-Host "No -FunctionUrl or -GitHubPat provided." -ForegroundColor Yellow
    Write-Host "  Production (recommended): provide -FunctionUrl (output of Deploy-GitHubRelayFunction.ps1)"
    Write-Host "  POC/fallback: provide -GitHubPat"
    Write-Host ''
    $FunctionUrl = Read-Host 'Azure Function URL (leave blank to use PAT fallback)'
    if ([string]::IsNullOrWhiteSpace($FunctionUrl)) {
        $GitHubPat = Read-Host 'GitHub fine-grained PAT (Contents: Read+Write on deployment repo)'
    }
}

if ([string]::IsNullOrWhiteSpace($JFrogToken)) {
    $JFrogToken = Read-Host 'JFrog access token (admin scope)'
}
if ([string]::IsNullOrWhiteSpace($JFrogToken)) { throw '-JFrogToken is required.' }

$useFunction = -not [string]::IsNullOrWhiteSpace($FunctionUrl)
$mode = if ($useFunction) { 'Azure Function relay (no static PAT)' } else { 'Direct GitHub PAT (POC mode)' }
Write-Host "Mode: $mode" -ForegroundColor $(if ($useFunction) { 'Green' } else { 'Yellow' })
Write-Host ''

$jfHeaders = @{ Authorization = "Bearer $JFrogToken"; 'Content-Type' = 'application/json' }
$subscriptionUrl = "$JFrogUrl/event/api/v1/subscriptions"

if ($useFunction) {

    Write-Host "Testing Azure Function endpoint..." -ForegroundColor Cyan
    $testBody = '{"event_type":"webhook-connectivity-test","client_payload":{"artifact_path":"test","repo_key":"test"}}'
    $testResp = Invoke-WebRequest -Uri $FunctionUrl -Method POST -Body $testBody -ContentType 'application/json' -UseBasicParsing -ErrorAction SilentlyContinue
    if ($testResp.StatusCode -in @(200, 204)) {
        Write-Host "Function endpoint reachable (HTTP $($testResp.StatusCode))." -ForegroundColor Green
    } else {
        Write-Warning "Function returned HTTP $($testResp.StatusCode) — proceeding anyway. Verify after webhook is created."
    }

    $bodyJson = @"
{
  "key": "$WebhookKey",
  "description": "Trigger $GitHubRepo deploy via Azure Function relay when artifact promoted from $SourceRepo",
  "enabled": true,
  "event_filter": {
    "domain": "artifact",
    "event_types": ["copied"],
    "criteria": {
      "repoKeys": ["$SourceRepo"],
      "includePatterns": ["**"]
    }
  },
  "handlers": [
    {
      "handler_type": "custom-webhook",
      "url": "FUNCTION_URL_PLACEHOLDER",
      "payload": "{\"event_type\": \"artifact-promoted\", \"client_payload\": {\"artifact_path\": \"{{ .data.path }}\", \"repo_key\": \"{{ .data.target_repo_path }}\"}}",
      "http_headers": [
        { "name": "Content-Type", "value": "application/json" }
      ]
    }
  ]
}
"@
    $bodyJson = $bodyJson -replace 'FUNCTION_URL_PLACEHOLDER', $FunctionUrl

} else {

    $dispatchUrl = "https://api.github.com/repos/$GitHubRepo/dispatches"

    Write-Host "Testing GitHub PAT against $dispatchUrl ..." -ForegroundColor Cyan
    $testBody = '{"event_type":"webhook-test","client_payload":{"source":"jfrog-setup-test"}}'
    $testResp = Invoke-WebRequest `
        -Uri     $dispatchUrl `
        -Method  POST `
        -Headers @{ Authorization = "Bearer $GitHubPat"; Accept = 'application/vnd.github.v3+json'; 'Content-Type' = 'application/json' } `
        -Body    $testBody `
        -UseBasicParsing
    if ($testResp.StatusCode -ne 204) {
        throw "PAT test failed: HTTP $($testResp.StatusCode). Check PAT scope (Contents: Read+Write)."
    }
    Write-Host 'PAT valid.' -ForegroundColor Green

    $bodyJson = @"
{
  "key": "$WebhookKey",
  "description": "Trigger $GitHubRepo deploy when artifact promoted from $SourceRepo (PAT mode)",
  "enabled": true,
  "event_filter": {
    "domain": "artifact",
    "event_types": ["copied"],
    "criteria": {
      "repoKeys": ["$SourceRepo"],
      "includePatterns": ["**"]
    }
  },
  "handlers": [
    {
      "handler_type": "custom-webhook",
      "url": "$dispatchUrl",
      "payload": "{\"event_type\": \"artifact-promoted\", \"client_payload\": {\"artifact_path\": \"{{ .data.path }}\", \"repo_key\": \"{{ .data.target_repo_path }}\"}}",
      "secrets": [
        {
          "name": "ghpat",
          "value": "GHPAT_PLACEHOLDER"
        }
      ],
      "http_headers": [
        { "name": "Authorization",  "value": "Bearer {{ .secrets.ghpat }}" },
        { "name": "Accept",         "value": "application/vnd.github.v3+json" },
        { "name": "Content-Type",   "value": "application/json" }
      ]
    }
  ]
}
"@
    $bodyJson = $bodyJson -replace 'GHPAT_PLACEHOLDER', $GitHubPat
}

$bodyFile = [System.IO.Path]::GetTempFileName() + '.json'
[System.IO.File]::WriteAllText($bodyFile, $bodyJson, (New-Object System.Text.UTF8Encoding $false))

Write-Host "Checking if webhook '$WebhookKey' already exists ..." -ForegroundColor Cyan
$existing = $null
try {
    $existing = Invoke-RestMethod -Uri "$subscriptionUrl/$WebhookKey" -Method GET -Headers $jfHeaders -ErrorAction Stop
} catch {}

try {
    if ($existing.key -eq $WebhookKey) {
        Write-Host "Webhook '$WebhookKey' exists — updating..." -ForegroundColor Yellow
        Invoke-RestMethod -Uri "$subscriptionUrl/$WebhookKey" -Method PUT -Headers $jfHeaders -InFile $bodyFile -ContentType 'application/json' | Out-Null
    } else {
        Invoke-RestMethod -Uri $subscriptionUrl -Method POST -Headers $jfHeaders -InFile $bodyFile -ContentType 'application/json' | Out-Null
    }
} finally {
    Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Webhook '$WebhookKey' configured ($mode)." -ForegroundColor Green
Write-Host "Fires on : artifact copied FROM $SourceRepo (i.e. when promoted to prod)"
if ($useFunction) {
    Write-Host "Calls    : Azure Function -> GitHub App token -> GitHub dispatch"
    Write-Host "No PAT   : rotation not required. Token is generated fresh per invocation."
} else {
    Write-Host "Calls    : $dispatchUrl"
    Write-Host "PAT mode : rotate annually via rotate-webhook-pat.yml workflow"
}
Write-Host ''
Write-Host "To test  : jf rt copy dfcore-preprod-feed/DFCore-1.0.0.zip dfcore-prod-feed/"
Write-Host "To verify: Invoke-RestMethod '$subscriptionUrl/$WebhookKey' -Headers @{Authorization='Bearer <token>'}"
