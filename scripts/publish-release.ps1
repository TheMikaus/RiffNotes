param(
  [string]$Version,
  [string]$Repository,
  [string]$Token,
  [switch]$SkipBuild,
  [switch]$Draft,
  [switch]$Prerelease,
  [switch]$NoGitTagPush
)

$ErrorActionPreference = 'Stop'

function Get-RepoFromRemote {
  $remote = (git remote get-url origin).Trim()
  if ($remote -match 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/.]+)') {
    return "$($Matches.owner)/$($Matches.repo)"
  }
  throw "Unable to determine GitHub repository from origin remote: $remote"
}

function Get-VersionFromPubspec {
  $pubspec = Get-Content -Raw -Path (Join-Path $PSScriptRoot '..\pubspec.yaml')
  $match = [regex]::Match($pubspec, '^version:\s*(?<version>\S+)$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
  if (-not $match.Success) {
    throw 'Unable to read version from pubspec.yaml.'
  }
  return ($match.Groups['version'].Value -split '\+')[0]
}

function Get-ReleaseNotesPath {
  param([string]$ReleaseTag)

  $notesPath = Join-Path $PSScriptRoot "..\docs\releases\$ReleaseTag.md"
  if (-not (Test-Path $notesPath)) {
    throw "Release notes not found: $notesPath"
  }
  return (Resolve-Path $notesPath).Path
}

function Get-AssetName {
  param([string]$ReleaseTag)
  return "RiffNotes-$ReleaseTag-windows.zip"
}

function Invoke-GithubApi {
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Uri,
    [object]$Body,
    [string]$ContentType = 'application/json'
  )

  $headers = @{
    Authorization = "Bearer $Token"
    Accept        = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
  }

  if ($null -ne $Body) {
    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -Body $Body -ContentType $ContentType
  }

  return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
}

function Get-GhInstallHelp {
  return @"
GitHub CLI (gh) is required to run this release script when no -Token or GITHUB_TOKEN is provided.

Install GitHub CLI:
  winget install --id GitHub.cli
  # or: https://cli.github.com/

Then authenticate:
  gh auth login
  gh auth status
"@
}

function Assert-GhAvailable {
  $gh = Get-Command gh -ErrorAction SilentlyContinue
  if (-not $gh) {
    throw (Get-GhInstallHelp)
  }
}

function Assert-GhAuthenticated {
  $null = gh auth status 2>$null
  if ($LASTEXITCODE -ne 0) {
    throw @"
GitHub CLI is installed but not authenticated.

Run:
  gh auth login
  gh auth status
"@
  }
}

if (-not $Version) {
  $Version = Get-VersionFromPubspec
}

if ($Version.StartsWith('v')) {
  $releaseTag = $Version
} else {
  $releaseTag = "v$Version"
}

if (-not $Repository) {
  $Repository = Get-RepoFromRemote
}

if (-not $Token) {
  $Token = $env:GITHUB_TOKEN
}

if (-not $Token) {
  Assert-GhAvailable
  Assert-GhAuthenticated
  $Token = (gh auth token).Trim()
}

if (-not $Token) {
  throw @"
Unable to resolve a GitHub token.

Use one of:
  1) Pass -Token <token>
  2) Set GITHUB_TOKEN in your environment
  3) Install and authenticate GitHub CLI, then rerun:
     gh auth login
"@
}

$notesPath = Get-ReleaseNotesPath -ReleaseTag $releaseTag
$notes = Get-Content -Raw -Path $notesPath
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$releaseDir = Join-Path $root 'build\windows\x64\runner\Release'
$artifactsDir = Join-Path $root 'artifacts'
$zipPath = Join-Path $artifactsDir (Get-AssetName -ReleaseTag $releaseTag)

if (-not $SkipBuild) {
  Push-Location $root
  try {
    flutter build windows --release
  } finally {
    Pop-Location
  }
}

if (-not (Test-Path $releaseDir)) {
  throw "Windows release output not found: $releaseDir"
}

New-Item -ItemType Directory -Force -Path $artifactsDir | Out-Null
if (Test-Path $zipPath) {
  Remove-Item $zipPath -Force
}

Compress-Archive -Path (Join-Path $releaseDir '*') -DestinationPath $zipPath -Force

$releaseApi = "https://api.github.com/repos/$Repository/releases"
$existingRelease = $null
try {
  $existingRelease = Invoke-GithubApi -Method Get -Uri "$releaseApi/tags/$releaseTag"
} catch {
  $existingRelease = $null
}

$release = $null

if (-not $NoGitTagPush) {
  Push-Location $root
  try {
    if (-not (git tag --list $releaseTag)) {
      git tag -a $releaseTag -m "RiffNotes $releaseTag"
      git push origin $releaseTag
    }
  } finally {
    Pop-Location
  }
}

if ($existingRelease) {
  Write-Host "Release $releaseTag already exists on GitHub. Reusing existing release and continuing with asset upload."
  $release = $existingRelease
} else {
  $release = Invoke-GithubApi -Method Post -Uri $releaseApi -Body (@{
    tag_name         = $releaseTag
    name             = "RiffNotes $releaseTag"
    body             = $notes
    draft            = [bool]$Draft
    prerelease       = [bool]$Prerelease
    generate_release_notes = $false
  } | ConvertTo-Json -Depth 8)
}

$assetName = Split-Path -Leaf $zipPath
$existingAsset = $null
if ($release.assets) {
  $existingAsset = $release.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
}

if ($existingAsset) {
  Invoke-GithubApi -Method Delete -Uri "https://api.github.com/repos/$Repository/releases/assets/$($existingAsset.id)" | Out-Null
}

$uploadUri = $release.upload_url -replace '\{\?name,label\}', ''
$uploadUri = "${uploadUri}?name=$([uri]::EscapeDataString($assetName))"
$headers = @{
  Authorization = "Bearer $Token"
  Accept        = 'application/vnd.github+json'
  'X-GitHub-Api-Version' = '2022-11-28'
}

Invoke-RestMethod -Method Post -Uri $uploadUri -Headers $headers -InFile $zipPath -ContentType 'application/zip' | Out-Null

Write-Host "Created GitHub release $releaseTag for $Repository"
Write-Host "Asset: $zipPath"