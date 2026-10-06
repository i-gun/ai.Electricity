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

$verification = & $apksigner.FullName verify --print-certs $ApkPath
if ($LASTEXITCODE -ne 0) {
    throw 'APK signature verification failed; publication is forbidden.'
}
$certificates = @($verification | Select-String '^Signer #\d+ certificate SHA-256 digest: ([a-fA-F0-9]{64})$')
if ($certificates.Count -ne 1 -or
    $certificates[0].Matches[0].Groups[1].Value -ne $ExpectedCertificateSha256) {
    throw 'APK signing certificate does not match the pinned release certificate.'
}
Write-Output 'APK signature and pinned signing certificate verified.'