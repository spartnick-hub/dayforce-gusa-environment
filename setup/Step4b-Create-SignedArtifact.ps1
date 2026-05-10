<#
.SYNOPSIS
    Creates a SIGNED test artifact (DFCore-1.0.1.zip) from the unsigned source zip.
    Companion to Step4-Upload-Artifact.ps1.

.WHAT THIS DOES
    1. Checks signtool.exe is installed (tells you how if not)
    2. Creates a self-signed code signing cert in the local machine cert store (if not already)
    3. Signs all DLLs/EXEs inside web.rar using that cert
    4. Repacks web.rar and the outer zip as DFCore-1.0.1.zip
    5. Uploads DFCore-1.0.1.zip to JFrog dfcore-preprod-local/Dayforce/1.0.1/
    6. Stores the cert thumbprint in HCP Vault at secret/codesigning/cert -> thumbprint
       (this is what the verify-codesign composite action reads at deploy time)

.TWO TEST SCENARIOS
    DFCore-1.0.0.zip  (unsigned, already uploaded by Step4) -> code signing FAILS -> pipeline aborts
    DFCore-1.0.1.zip  (signed,   this script)               -> code signing PASSES -> pipeline continues

.PREREQUISITES
    signtool.exe installed locally:
        winget install Microsoft.WindowsSDK.10.0.26100
    7-Zip installed:
        winget install 7zip.7zip
    JFrog CLI configured (Step4 already did this):
        jf config show
    HCP Vault accessible (admin token or AppRole with write access)

.USAGE
    & "D:\Dayforce\repos\hcm\gusa-pipeline\setup\Step4b-Create-SignedArtifact.ps1"
#>

param(
    [string]$SourceZip      = "D:\Dayforce\resources\DFCoreArtifact\dayforce-gusa-1.0.0.zip",
    [string]$SignedVersion  = "1.0.1",
    [string]$JfrogRepo      = "dfcore-preprod-local",
    [string]$JfrogFolder    = "Dayforce",
    [string]$JfrogServerId  = "freenferal",
    [string]$JfrogCli       = "jf",
    [string]$SevenZip       = "C:\Program Files\7-Zip\7z.exe",
    [string]$CertSubject    = "CN=GUSA-CodeSign-Test",
    [string]$VaultAddr      = "https://vault-gusa-prod-public-vault-8632fb0b.fed357f8.z1.hashicorp.cloud:8200",
    [string]$VaultNamespace = "admin",
    [string]$VaultRoleId    = "3a4ceeda-3d40-1b93-3a41-05ed5cbc8ab2",
    [string]$VaultSecretId  = "",  # prompted if empty
    [string]$WorkDir        = "$env:TEMP\gusa-sign-$SignedVersion"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Step 4b: Create Signed Test Artifact ===" -ForegroundColor Cyan
Write-Host "Source     : $SourceZip"
Write-Host "Version    : $SignedVersion (signed)"
Write-Host "Output     : DFCore-$SignedVersion.zip -> $JfrogRepo/$JfrogFolder/$SignedVersion/"
Write-Host ""

# ==============================================================================
# 1. Check prerequisites
# ==============================================================================

# signtool.exe — try SDK paths and PATH
$signtool = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\bin\*\x64\signtool.exe" `
    -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
if (-not $signtool) {
    $signtool = (Get-Command signtool.exe -ErrorAction SilentlyContinue)?.Source
}
if (-not $signtool) {
    Write-Host ""
    Write-Host "ERROR: signtool.exe not found." -ForegroundColor Red
    Write-Host "Install the Windows SDK:"
    Write-Host "  winget install Microsoft.WindowsSDK.10.0.26100"
    Write-Host "Then re-run this script."
    exit 1
}
Write-Host "signtool : $signtool" -ForegroundColor Green

if (-not (Test-Path $SevenZip)) {
    Write-Host ""
    Write-Host "ERROR: 7-Zip not found at $SevenZip" -ForegroundColor Red
    Write-Host "Install: winget install 7zip.7zip"
    exit 1
}
Write-Host "7-Zip    : $SevenZip" -ForegroundColor Green

if (-not (Test-Path $SourceZip)) { throw "Source zip not found: $SourceZip" }
Write-Host "Source   : $SourceZip" -ForegroundColor Green
Write-Host ""

# ==============================================================================
# 2. Get or create self-signed code signing certificate
# ==============================================================================
Write-Host "Checking for self-signed cert '$CertSubject' ..." -ForegroundColor Cyan

$cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -eq $CertSubject } | Select-Object -First 1

if (-not $cert) {
    Write-Host "Creating self-signed code signing cert ..." -ForegroundColor Cyan
    $cert = New-SelfSignedCertificate `
        -Subject         $CertSubject `
        -CertStoreLocation "Cert:\LocalMachine\My" `
        -KeyUsage        DigitalSignature `
        -Type            CodeSigningCert `
        -NotAfter        (Get-Date).AddYears(5) `
        -HashAlgorithm   SHA256
    Write-Host "Cert created." -ForegroundColor Green
} else {
    Write-Host "Found existing cert." -ForegroundColor Green
}

$sha1Thumbprint = $cert.Thumbprint
$sha256 = [System.Security.Cryptography.SHA256]::Create()
try {
    $cert2        = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($cert)
    $hashBytes    = $sha256.ComputeHash($cert2.RawData)
    $thumbprint   = [BitConverter]::ToString($hashBytes).Replace('-','').ToUpperInvariant()
} finally {
    $sha256.Dispose()
}
Write-Host "SHA-1 thumbprint (Windows display) : $sha1Thumbprint" -ForegroundColor DarkGray
Write-Host "SHA-256 thumbprint (Vault / verify) : $thumbprint" -ForegroundColor Green
Write-Host "(SHA-1 is disallowed per NIST SP 800-131A rev 2 / FedRAMP — SHA-256 stored in Vault)" -ForegroundColor DarkYellow
Write-Host ""

# ==============================================================================
# 3. Store SHA-256 thumbprint in HCP Vault
# NIST SP 800-131A rev 2 / FedRAMP: SHA-1 is disallowed for cryptographic identification.
# Only the SHA-256 thumbprint (64 hex chars) is stored and used for verification.
# The verify-codesign composite action reads this same path at deploy time.
# ==============================================================================
Write-Host "Storing SHA-256 thumbprint in HCP Vault at secret/codesigning/cert ..." -ForegroundColor Cyan

if ([string]::IsNullOrWhiteSpace($VaultSecretId)) {
    $VaultSecretId = Read-Host "HCP Vault AppRole Secret ID (HC_VAULT_SECRET_ID)"
}
if ([string]::IsNullOrWhiteSpace($VaultSecretId)) { throw "Vault Secret ID is required." }

$baseUrl     = "$VaultAddr/v1"
$vaultHdrs   = @{ "X-Vault-Namespace" = $VaultNamespace }

$loginBody  = @{ role_id = $VaultRoleId; secret_id = $VaultSecretId } | ConvertTo-Json
$loginResp  = Invoke-RestMethod -Uri "$baseUrl/auth/approle/login" -Method POST `
    -Body $loginBody -ContentType "application/json" -Headers $vaultHdrs
$token = $loginResp.auth.client_token
if ([string]::IsNullOrWhiteSpace($token)) { throw "Vault AppRole login failed." }
$vaultHdrs["X-Vault-Token"] = $token

$secretBody = @{ data = @{ thumbprint = $thumbprint; thumbprint_algorithm = 'SHA-256' } } | ConvertTo-Json
Invoke-RestMethod -Uri "$baseUrl/secret/data/codesigning/cert" -Method POST `
    -Body $secretBody -ContentType "application/json" -Headers $vaultHdrs | Out-Null

$vaultHdrs.Remove("X-Vault-Token")
Write-Host "SHA-256 thumbprint stored in Vault at secret/codesigning/cert -> thumbprint" -ForegroundColor Green
Write-Host ""

# ==============================================================================
# 4. Extract, sign DLLs/EXEs, repack
# Structure: DFCore-1.0.0.zip contains web.rar (and bje.rar, db.rar, etc.)
# We only need to re-sign DLLs inside web.rar - that is what verify-codesign checks.
# ==============================================================================
Write-Host "Setting up work directory: $WorkDir" -ForegroundColor Cyan
Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

$extractDir = "$WorkDir\extracted"
$webRarDir  = "$WorkDir\web-contents"
New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
New-Item -ItemType Directory -Path $webRarDir  -Force | Out-Null

# Extract full zip to get web.rar (and keep all other rars untouched)
Write-Host "Extracting source zip ..." -ForegroundColor Cyan
& $SevenZip x -y "$SourceZip" "-o$extractDir" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to extract source zip." }

$webRar = "$extractDir\web.rar"
if (-not (Test-Path $webRar)) { throw "web.rar not found inside the source zip. Check zip structure." }

# Extract web.rar to sign its contents
Write-Host "Extracting web.rar ..." -ForegroundColor Cyan
& $SevenZip x -y "$webRar" "-o$webRarDir" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to extract web.rar." }

# Sign every DLL and EXE found inside web.rar contents
$targets = Get-ChildItem $webRarDir -Recurse -Include "*.dll","*.exe" -ErrorAction SilentlyContinue
Write-Host "Signing $($targets.Count) file(s) ..." -ForegroundColor Cyan

foreach ($file in $targets) {
    & $signtool sign /fd SHA256 /sha1 $thumbprint /td SHA256 /tr http://timestamp.digicert.com `
        "$($file.FullName)" 2>&1 | Out-Null
    # Timestamp server may fail in offline/restricted environments - sign without if needed
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Retry without timestamp: $($file.Name)" -ForegroundColor Yellow
        & $signtool sign /fd SHA256 /sha1 $thumbprint "$($file.FullName)" 2>&1 | Out-Null
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to sign: $($file.FullName)"
    } else {
        Write-Host "  Signed: $($file.Name)" -ForegroundColor Green
    }
}

# Repack web.rar with signed contents
Write-Host "Repacking web.rar ..." -ForegroundColor Cyan
$signedWebRar = "$WorkDir\web.rar"
Remove-Item $webRar -Force  # remove old unsigned web.rar from extracted dir
& $SevenZip a -r "$signedWebRar" "$webRarDir\*" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to repack web.rar." }

# Replace unsigned web.rar in extracted dir with signed one
Copy-Item $signedWebRar "$extractDir\web.rar" -Force

# Repack full zip as DFCore-1.0.1.zip
$targetName  = "DFCore-$SignedVersion.zip"
$signedZip   = "$WorkDir\$targetName"
Write-Host "Repacking as $targetName ..." -ForegroundColor Cyan
& $SevenZip a "$signedZip" "$extractDir\*" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to create signed zip." }

Write-Host "Signed zip created: $signedZip" -ForegroundColor Green
Write-Host ""

# ==============================================================================
# 5. Upload to JFrog
# ==============================================================================
Write-Host "Uploading $targetName to JFrog ..." -ForegroundColor Cyan

$targetPath = "$JfrogRepo/$JfrogFolder/$SignedVersion/$targetName"
& $JfrogCli rt upload "$signedZip" "$targetPath" --server-id $JfrogServerId
if ($LASTEXITCODE -ne 0) { throw "JFrog upload failed." }

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Green
Write-Host ""
Write-Host "Uploaded : $targetPath" -ForegroundColor Green
Write-Host "SHA-256 thumbprint in Vault: secret/codesigning/cert -> thumbprint = $thumbprint"
Write-Host "(64 hex chars, SHA-256 — FedRAMP / NIST SP 800-131A compliant)"
Write-Host ""
Write-Host "Test scenarios:"
Write-Host "  Fail-fast (unsigned) : trigger workflow with version 1.0.0 -> code signing FAILS"
Write-Host "  Success  (signed)    : trigger workflow with version 1.0.1 -> code signing PASSES"
Write-Host ""
Write-Host "Trigger:"
Write-Host "  gh workflow run deploy-gusa.yml --field build_version=1.0.1 --repo spartnick-hub/dayforce-gusa-deployment"

# Cleanup work dir
Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
