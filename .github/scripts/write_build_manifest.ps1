[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StagingDirectory,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [Parameter(Mandatory = $true)][string]$SourceRef,
    [Parameter(Mandatory = $true)][string]$CommitSha,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$RunnerOS,
    [Parameter(Mandatory = $true)][string]$FlutterVersion,
    [Parameter(Mandatory = $true)][string]$DartVersion
)

$ErrorActionPreference = 'Stop'
$staging = [IO.Path]::GetFullPath($StagingDirectory)
$output = [IO.Path]::GetFullPath($OutputDirectory)
function Get-SafeRelativePath([string]$Base, [string]$Path) {
    $prefix = $Base.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Path is outside the expected root.' }
    return $Path.Substring($prefix.Length).Replace('\', '/')
}
New-Item -ItemType Directory -Force -Path $output | Out-Null
$entries = @(Get-Content -Raw -LiteralPath (Join-Path $staging 'entries.json') | ConvertFrom-Json)
$manifestEntries = @()
$checksumLines = @()
foreach ($entry in $entries) {
    $artifactPath = [IO.Path]::GetFullPath((Join-Path $staging $entry.path))
    if (-not $artifactPath.StartsWith($staging, [StringComparison]::OrdinalIgnoreCase)) { throw 'Artifact path escaped staging.' }
    $files = @(Get-ChildItem -LiteralPath $artifactPath -File -Recurse | Sort-Object FullName)
    if ($files.Count -eq 0) { throw "Artifact has no files: $($entry.path)" }
    $parts = @()
    $bytes = [int64]0
    foreach ($file in $files) {
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
        $relativeFile = Get-SafeRelativePath $staging $file.FullName
        $parts += "$relativeFile=$hash"
        $bytes += $file.Length
        $checksumLines += "$hash  $relativeFile"
    }
    $aggregate = [Security.Cryptography.SHA256]::Create()
    $aggregateHash = ([BitConverter]::ToString($aggregate.ComputeHash([Text.Encoding]::UTF8.GetBytes(($parts -join "`n"))))).Replace('-', '').ToLowerInvariant()
    $aggregate.Dispose()
    $manifestEntries += [ordered]@{ platform = $entry.platform; build_mode = $entry.build_mode; format = $entry.format; relative_artifact_path = $entry.path; byte_size = $bytes; sha256 = $aggregateHash; build_status = 'completed'; warnings = @() }
}
$manifest = [ordered]@{
    schema = 'code-build-artifact-manifest/v1'
    workflow_run_id = $RunId
    timestamp = [DateTime]::UtcNow.ToString('o')
    source_ref = $SourceRef
    commit_sha = $CommitSha
    runner_os = $RunnerOS
    flutter_version = $FlutterVersion.Trim()
    dart_version = $DartVersion.Trim()
    artifacts = $manifestEntries
    warnings = @()
}
$manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $output 'manifest.json') -Encoding utf8
$checksumLines | Set-Content -LiteralPath (Join-Path $output 'SHA256SUMS') -Encoding utf8
Write-Output ($manifest | ConvertTo-Json -Depth 10)