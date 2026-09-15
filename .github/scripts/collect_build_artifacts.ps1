[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('windows', 'macos', 'linux', 'android', 'ios')][string]$Platform,
    [Parameter(Mandatory = $true)][ValidateSet('debug', 'profile', 'release')][string]$BuildMode,
    [Parameter(Mandatory = $true)][ValidateSet('bundle', 'apk', 'simulator-app')][string]$Format,
    [Parameter(Mandatory = $true)][string]$Workspace,
    [Parameter(Mandatory = $true)][string]$StagingDirectory
)

$ErrorActionPreference = 'Stop'
$workspaceFull = [IO.Path]::GetFullPath($Workspace)
$stagingFull = [IO.Path]::GetFullPath($StagingDirectory)
function Get-SafeRelativePath([string]$Base, [string]$Path) {
    $prefix = $Base.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Path is outside the expected root.' }
    return $Path.Substring($prefix.Length).Replace('\', '/')
}
New-Item -ItemType Directory -Force -Path $stagingFull | Out-Null
$modeName = (Get-Culture).TextInfo.ToTitleCase($BuildMode)
$candidates = switch ($Platform) {
    'windows' { @(Join-Path $workspaceFull "apps/desktop/build/windows/x64/runner/$modeName") }
    'macos' { @(Join-Path $workspaceFull "apps/desktop/build/macos/Build/Products/$modeName/*.app") }
    'linux' { @(Join-Path $workspaceFull "apps/desktop/build/linux/x64/$modeName/bundle") }
    'android' { @(Join-Path $workspaceFull "apps/mobile/build/app/outputs/flutter-apk/app-$BuildMode.apk") }
    'ios' { @(Join-Path $workspaceFull 'apps/mobile/build/ios/iphonesimulator/*.app') }
}
$source = $null
foreach ($candidate in $candidates) {
    $match = Get-Item -LiteralPath $candidate -ErrorAction SilentlyContinue
    if (-not $match) { $match = Get-Item -Path $candidate -ErrorAction SilentlyContinue }
    if ($match) { $source = $match | Select-Object -First 1; break }
}
if (-not $source) { throw "No real output found for $Platform/$BuildMode ($Format)." }
$sourceFull = [IO.Path]::GetFullPath($source.FullName)
if (-not $sourceFull.StartsWith($workspaceFull, [StringComparison]::OrdinalIgnoreCase)) { throw 'Artifact source escaped the workspace.' }
$destination = Join-Path $stagingFull "$Platform-$BuildMode-$Format"
if (Test-Path -LiteralPath $destination) { Remove-Item -Recurse -Force -LiteralPath $destination }
if ($source.PSIsContainer) { Copy-Item -Recurse -Force -LiteralPath $sourceFull -Destination $destination } else {
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    Copy-Item -Force -LiteralPath $sourceFull -Destination (Join-Path $destination $source.Name)
}
$relative = Get-SafeRelativePath $stagingFull $destination
$entry = [ordered]@{ platform = $Platform; build_mode = $BuildMode; format = $Format; path = $relative }
$entry | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $stagingFull 'entries.json') -Encoding utf8
Write-Output ($entry | ConvertTo-Json -Compress)