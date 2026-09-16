[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Platforms,
    [Parameter(Mandatory = $true)][string]$ArtifactFormats,
    [Parameter(Mandatory = $true)][ValidateSet('debug', 'profile', 'release')][string]$BuildMode,
    [Parameter(Mandatory = $true)][string]$Confirmation,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$allowedFormats = @{
    windows = 'bundle'
    macos = 'bundle'
    linux = 'bundle'
    android = 'apk'
    ios = 'simulator-app'
}
$allowedPlatforms = @($allowedFormats.Keys | Sort-Object)

if ($Confirmation -cne 'confirmed') { throw 'Confirmation must be exactly confirmed.' }
try { $selectedPlatforms = @((ConvertFrom-Json -InputObject $Platforms) | ForEach-Object { $_ }) } catch { throw 'Platforms must be a JSON array.' }
$invalidPlatformValues = @($selectedPlatforms | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) })
if ($selectedPlatforms.Count -eq 0 -or $invalidPlatformValues.Count -gt 0) {
    throw 'Platforms must be a non-empty JSON array of strings.'
}
$normalizedPlatforms = @($selectedPlatforms | ForEach-Object { $_.ToLowerInvariant() })
if (@($normalizedPlatforms | Sort-Object -Unique).Count -ne $normalizedPlatforms.Count) { throw 'Platforms must not contain duplicates.' }
foreach ($platform in $normalizedPlatforms) {
    if ($allowedPlatforms -notcontains $platform) { throw "Unknown platform: $platform" }
    if ($platform -eq 'android' -and $BuildMode -ne 'release') { throw 'Android release APKs require release build mode.' }
}
try { $formatMap = ConvertFrom-Json -InputObject $ArtifactFormats } catch { throw 'ArtifactFormats must be a JSON object.' }
foreach ($platform in $normalizedPlatforms) {
    $format = [string]$formatMap.$platform
    if ([string]::IsNullOrWhiteSpace($format) -or $format -ne $allowedFormats[$platform]) {
        throw "Unsupported or missing format for $platform. Expected $($allowedFormats[$platform])."
    }
}
$extraFormats = @($formatMap.psobject.Properties.Name | Where-Object { $normalizedPlatforms -notcontains $_ })
if ($extraFormats.Count -gt 0) { throw "Artifact formats contain unselected platforms: $($extraFormats -join ', ')." }

$matrix = @($normalizedPlatforms | ForEach-Object {
    $platform = $_
    $runner = switch ($platform) {
        'windows' { 'windows-latest' }
        'macos' { 'macos-latest' }
        'ios' { 'macos-latest' }
        'linux' { 'ubuntu-latest' }
        'android' { 'ubuntu-latest' }
    }
    [ordered]@{ platform = $platform; format = $allowedFormats[$platform]; runner = $runner }
})
$result = [ordered]@{ platforms = $normalizedPlatforms; build_mode = $BuildMode; formats = $formatMap; matrix = $matrix }
$json = $result | ConvertTo-Json -Compress -Depth 10
if ($OutputPath) { Set-Content -LiteralPath $OutputPath -Value $json -Encoding utf8 }
Write-Output $json