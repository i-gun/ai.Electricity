param(
    [Parameter(Mandatory = $true)]
    [string]$ApkPath,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-fA-F0-9]{64}$')]
    [string]$ExpectedCertificateSha256,
    [string]$AndroidSdkPath = $env:ANDROID_HOME
)

$ErrorActionPreference = 'Stop'
if (-not $AndroidSdkPath) {
    $AndroidSdkPath = $env:ANDROID_SDK_ROOT
}
if (-not $AndroidSdkPath -or -not (Test-Path -LiteralPath $ApkPath -PathType Leaf)) {
    throw 'An Android SDK and an existing APK are required.'
}

$apksigner = Get-ChildItem (Join-Path $AndroidSdkPath 'build-tools/*/apksigner*') |
    Where-Object { $_.Name -in @('apksigner', 'apksigner.bat') } |
    Sort-Object { [version]$_.Directory.Name } -Descending |
    Select-Object -First 1
if (-not $apksigner) {
    throw 'Android SDK build-tools must provide apksigner.'
}

$verification = & $apksigner.FullName verify --verbose --print-certs $ApkPath
if ($LASTEXITCODE -ne 0) {
    throw 'APK signature verification failed; publication is forbidden.'
}
$signers = @($verification | Select-String '^Number of signers: 1$')
if ($signers.Count -ne 1) {
    $verification | Write-Output
    throw 'Expected exactly one APK signer.'
}
$certificatePattern = '^(?:Signer (?:#\d+|\(minSdkVersion=\d+(?: \(dev release=true\))?, maxSdkVersion=\d+\))|V[123](?:\.\d+)? Signer(?: \(.*\))?:) certificate SHA-256 digest: ([a-fA-F0-9]{64})$'
$certificates = @($verification | Select-String $certificatePattern)
if ($certificates.Count -eq 0) {
    $verification | Write-Output
    throw 'No recognized APK signing certificate digest was reported.'
}
foreach ($certificate in $certificates) {
    $actualCertificateSha256 = $certificate.Matches[0].Groups[1].Value
    if ($actualCertificateSha256 -ne $ExpectedCertificateSha256) {
        throw "APK signing certificate mismatch. Expected: $ExpectedCertificateSha256; actual: $actualCertificateSha256"
    }
}
Write-Output 'APK signature and pinned signing certificate verified.'