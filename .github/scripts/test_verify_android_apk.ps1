[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'verify_android_apk.ps1'
$expectedCertificate = 'a' * 64
$wrongCertificate = 'b' * 64

function Get-ChildItem {
    [pscustomobject]@{
        Name = 'apksigner'
        FullName = 'Invoke-ApksignerFixture'
        Directory = [pscustomobject]@{ Name = '37.0.0' }
    }
}

function Invoke-ApksignerFixture {
    $global:LASTEXITCODE = $fixtureExitCode
    $fixtureOutput
}

function Assert-Accepted([string[]]$Output) {
    $script:fixtureOutput = $Output
    $script:fixtureExitCode = 0
    & $scriptPath -ApkPath $PSCommandPath -ExpectedCertificateSha256 $expectedCertificate.ToUpperInvariant() -AndroidSdkPath 'fixture-sdk' | Out-Null
}

function Assert-Rejected([string[]]$Output, [int]$ExitCode, [string]$Expected) {
    $script:fixtureOutput = $Output
    $script:fixtureExitCode = $ExitCode
    try {
        & $scriptPath -ApkPath $PSCommandPath -ExpectedCertificateSha256 $expectedCertificate -AndroidSdkPath 'fixture-sdk' | Out-Null
        throw 'Expected APK rejection.'
    } catch {
        if ($_.Exception.Message -notlike "*$Expected*") { throw }
    }
}

$numbered = @('Number of signers: 1', "Signer #1 certificate SHA-256 digest: $expectedCertificate")
$sdkRanges = @(
    'Number of signers: 1',
    "Signer (minSdkVersion=33, maxSdkVersion=2147483647) certificate SHA-256 digest: $expectedCertificate",
    "Signer (minSdkVersion=24, maxSdkVersion=32) certificate SHA-256 digest: $expectedCertificate"
)
Assert-Accepted $numbered
Assert-Accepted $sdkRanges
Assert-Accepted @('Number of signers: 1', "Signer (minSdkVersion=33 (dev release=true), maxSdkVersion=2147483647) certificate SHA-256 digest: $expectedCertificate")
Assert-Accepted @('Number of signers: 1', "V2 Signer: certificate SHA-256 digest: $expectedCertificate")
Assert-Accepted @('Number of signers: 1', "V2 Signer: certificate SHA-256 digest: $expectedCertificate", "V3 Signer (minSdkVersion=24, maxSdkVersion=2147483647): certificate SHA-256 digest: $expectedCertificate")
Assert-Rejected @('DOES NOT VERIFY') 1 'signature verification failed'
Assert-Rejected @('Number of signers: 1') 0 'No recognized'
Assert-Rejected @('Number of signers: 2', "Signer #1 certificate SHA-256 digest: $expectedCertificate", "Signer #2 certificate SHA-256 digest: $expectedCertificate") 0 'exactly one APK signer'
Assert-Rejected @('Number of signers: 1', "Signer #1 certificate SHA-256 digest: $wrongCertificate") 0 'certificate mismatch'
Assert-Rejected ($sdkRanges + "Signer (minSdkVersion=21, maxSdkVersion=23) certificate SHA-256 digest: $wrongCertificate") 0 'certificate mismatch'
Assert-Rejected @('Number of signers: 1', "Source Stamp Signer certificate SHA-256 digest: $expectedCertificate") 0 'No recognized'
Assert-Rejected @('Number of signers: 1', "Signer #1 public key SHA-256 digest: $expectedCertificate") 0 'No recognized'
Assert-Rejected @('Number of signers: 1', "V2 Signer: certificate SHA-256 digest: $expectedCertificate", "V3 Signer: certificate SHA-256 digest: $wrongCertificate") 0 'certificate mismatch'
Assert-Rejected @('Number of signers: 1', "V2 Signer: public key SHA-256 digest: $expectedCertificate") 0 'No recognized'
Write-Output 'All 14 APK signature verification regression tests passed.'