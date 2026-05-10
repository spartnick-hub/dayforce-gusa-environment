
$ErrorActionPreference = 'Stop'

Write-Host "=== Step 4: Upload artifact to JFrog ===" -ForegroundColor Cyan

$sourceZip   = "D:\Dayforce\resources\DFCoreArtifact\dayforce-gusa-1.0.0.zip"
$version     = "1.0.0"
$targetName  = "DFCore-$version.zip"
# Unsigned artifacts go to dfcore-dev-local — never to prod.
# Signed artifacts (Step4b) go to dfcore-prod-local.
# This mirrors the real CI/CD flow: CI builds to dev, signing + promotion pushes to prod.
$targetPath  = "dfcore-dev-local/Dayforce/$version/$targetName"
$renamedPath = "$env:TEMP\$targetName"

if (-not (Test-Path $sourceZip)) { throw "Source zip not found: $sourceZip" }

Write-Host "Renaming to $targetName..."
Copy-Item $sourceZip $renamedPath -Force

Write-Host "Uploading to JFrog: $targetPath"
& "$env:USERPROFILE\jf.exe" rt upload `
    "$renamedPath" `
    "$targetPath" `
    --server-id freenferal

if ($LASTEXITCODE -ne 0) { throw "JFrog upload failed." }
Write-Host "Upload complete: $targetPath" -ForegroundColor Green

Remove-Item $renamedPath -Force -ErrorAction SilentlyContinue
