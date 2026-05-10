param($Request, $TriggerMetadata)

$ErrorActionPreference = 'Stop'

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    [Convert]::ToBase64String($Bytes).Replace('+', '-').Replace('/', '_').TrimEnd('=')
}

function New-GitHubAppJWT {
    param([string]$AppId, [string]$PrivateKeyPem)

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $header  = ConvertTo-Base64Url ([System.Text.Encoding]::UTF8.GetBytes('{"alg":"RS256","typ":"JWT"}'))
    $payload = ConvertTo-Base64Url ([System.Text.Encoding]::UTF8.GetBytes("{`"iat`":$($now - 60),`"exp`":$($now + 540),`"iss`":`"$AppId`"}"))
    $input   = "$header.$payload"

    $rsa = [System.Security.Cryptography.RSA]::Create()
    $rsa.ImportFromPem($PrivateKeyPem)
    $sig = $rsa.SignData(
        [System.Text.Encoding]::ASCII.GetBytes($input),
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
    )
    "$input.$(ConvertTo-Base64Url $sig)"
}

function Get-KeyVaultSecret {
    param([string]$VaultName, [string]$SecretName)

    $tokenResp = Invoke-RestMethod `
        -Uri     "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net" `
        -Headers @{ Metadata = 'true' }
    $kvToken = $tokenResp.access_token

    $secretResp = Invoke-RestMethod `
        -Uri     "https://$VaultName.vault.azure.net/secrets/$SecretName`?api-version=7.4" `
        -Headers @{ Authorization = "Bearer $kvToken" }
    $secretResp.value
}

try {
    Write-Host "GusaGitHubRelay: request received from $($Request.Headers.'x-forwarded-for')"

    $body = $Request.Body
    if ($body -is [string]) { $body = $body | ConvertFrom-Json }

    $eventType    = $body.event_type
    $artifactPath = $body.client_payload.artifact_path
    $repoKey      = $body.client_payload.repo_key

    if ($eventType -ne 'artifact-promoted') {
        Write-Host "Ignoring event_type '$eventType' — expected 'artifact-promoted'"
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = 200; Body = 'ignored' })
        return
    }

    Write-Host "artifact_path : $artifactPath"
    Write-Host "repo_key      : $repoKey"

    $kvName = $env:KEY_VAULT_NAME
    $appId  = $env:GITHUB_APP_ID
    $ghRepo = $env:GITHUB_REPO

    if (-not $kvName -or -not $appId -or -not $ghRepo) {
        throw "Missing required app settings: KEY_VAULT_NAME, GITHUB_APP_ID, GITHUB_REPO"
    }

    Write-Host "Reading GitHub App private key from Key Vault '$kvName'..."
    $privateKeyPem = Get-KeyVaultSecret -VaultName $kvName -SecretName 'github-app-private-key'

    Write-Host "Generating GitHub App JWT (App ID: $appId)..."
    $jwt = New-GitHubAppJWT -AppId $appId -PrivateKeyPem $privateKeyPem

    $ghHeaders = @{
        Authorization = "Bearer $jwt"
        Accept        = 'application/vnd.github.v3+json'
        'User-Agent'  = 'gusa-github-relay/1.0'
    }

    Write-Host "Resolving GitHub App installation for $ghRepo..."
    $orgName = $ghRepo.Split('/')[0]
    $installations = Invoke-RestMethod -Uri 'https://api.github.com/app/installations' -Headers $ghHeaders
    $install = $installations | Where-Object { $_.account.login -eq $orgName } | Select-Object -First 1
    if (-not $install) {
        throw "GitHub App (ID: $appId) has no installation for org/user '$orgName'. Install at https://github.com/settings/apps."
    }

    Write-Host "Requesting installation token (installation $($install.id))..."
    $tokenResp = Invoke-RestMethod `
        -Uri     "https://api.github.com/app/installations/$($install.id)/access_tokens" `
        -Method  POST `
        -Headers $ghHeaders
    $installToken = $tokenResp.token

    Write-Host "Dispatching repository_dispatch to $ghRepo..."
    $dispatchBody = @{
        event_type     = 'artifact-promoted'
        client_payload = @{
            artifact_path = $artifactPath
            repo_key      = $repoKey
        }
    } | ConvertTo-Json -Compress

    Invoke-RestMethod `
        -Uri     "https://api.github.com/repos/$ghRepo/dispatches" `
        -Method  POST `
        -Headers @{
            Authorization  = "Bearer $installToken"
            Accept         = 'application/vnd.github.v3+json'
            'Content-Type' = 'application/json'
            'User-Agent'   = 'gusa-github-relay/1.0'
        } `
        -Body $dispatchBody | Out-Null

    Write-Host "Dispatch sent. artifact_path=$artifactPath repo_key=$repoKey" -ForegroundColor Green

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 200
        Body       = "dispatched: $artifactPath"
    })

} catch {
    Write-Error "GusaGitHubRelay ERROR: $_"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 500
        Body       = "relay error — check Application Insights for details"
    })
}
