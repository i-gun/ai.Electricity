[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'validate_build_inputs.ps1'

function Assert-Rejected([hashtable]$Case, [string]$Expected) {
    try {
        & $scriptPath -Platforms $Case.Platforms -ArtifactFormats $Case.Formats -BuildMode $Case.Mode -Confirmation $Case.Confirmation | Out-Null
        throw "Expected rejection for $($Case.Name)."
    } catch {
        if ($_.Exception.Message -notlike "*$Expected*") { throw "Unexpected rejection for $($Case.Name): $($_.Exception.Message)" }
    }
}

$valid = & $scriptPath -Platforms '["windows","android"]' -ArtifactFormats '{"windows":"bundle","android":"apk"}' -BuildMode debug -Confirmation confirmed | ConvertFrom-Json
if ($valid.platforms.Count -ne 2 -or $valid.matrix[1].runner -ne 'ubuntu-latest') { throw 'Valid matrix was not normalized as expected.' }
Assert-Rejected @{ Name = 'confirmation'; Platforms = '["windows"]'; Formats = '{"windows":"bundle"}'; Mode = 'debug'; Confirmation = 'yes' } 'exactly confirmed'
Assert-Rejected @{ Name = 'malformed'; Platforms = '["windows"'; Formats = '{"windows":"bundle"}'; Mode = 'debug'; Confirmation = 'confirmed' } 'JSON array'
Assert-Rejected @{ Name = 'duplicate'; Platforms = '["windows","windows"]'; Formats = '{"windows":"bundle"}'; Mode = 'debug'; Confirmation = 'confirmed' } 'duplicates'
Assert-Rejected @{ Name = 'unknown'; Platforms = '["web"]'; Formats = '{"web":"bundle"}'; Mode = 'debug'; Confirmation = 'confirmed' } 'Unknown platform'
Assert-Rejected @{ Name = 'host-mode'; Platforms = '["android"]'; Formats = '{"android":"apk"}'; Mode = 'release'; Confirmation = 'confirmed' } 'debug APK only'
Write-Output 'All build input validation tests passed.'
exit 0