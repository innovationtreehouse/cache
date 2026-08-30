#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Download the latest GitHub Release and install the Windows client.
#>
[CmdletBinding()]
param(
    [string]$GitHubRepo = $(if ($env:GITHUB_REPO) { $env:GITHUB_REPO } else { 'innovationtreehouse/cache' }),
    # Immutable numeric id of GitHubRepo — a re-registered name cannot fake it.
    [string]$GitHubRepoId = $(if ($env:GITHUB_REPO_ID) { $env:GITHUB_REPO_ID } else { '1343160243' }),
    [string]$GitHubToken = $(if ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { '' })
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Boot([string]$Msg, [string]$Color = 'Cyan') {
    Write-Host "  $Msg" -ForegroundColor $Color
}

Write-Host ''
Write-Host '  facility-cache-client' -ForegroundColor Cyan -NoNewline
Write-Host '  bootstrap from GitHub' -ForegroundColor DarkGray
Write-Host ('  ' + ('-' * 48)) -ForegroundColor DarkGray
Write-Boot "github  $GitHubRepo"

$headers = @{
    'User-Agent' = 'facility-cache-client-bootstrap'
    Accept       = 'application/vnd.github+json'
}
if ($GitHubToken) { $headers['Authorization'] = "Bearer $GitHubToken" }

if ($GitHubRepoId) {
    $meta = Invoke-RestMethod -Uri "https://api.github.com/repos/$GitHubRepo" -Headers $headers
    if ([string]$meta.id -ne [string]$GitHubRepoId) {
        Write-Host "  X  repo id $($meta.id) does not match pinned $GitHubRepoId — refusing to install" -ForegroundColor Red
        throw 'Repository id mismatch (name may have been re-registered)'
    }
    Write-Boot "repo id $GitHubRepoId" 'Green'
}

$release = Invoke-RestMethod -Uri "https://api.github.com/repos/$GitHubRepo/releases/latest" -Headers $headers
$assets = @{}
foreach ($a in $release.assets) { $assets[$a.name] = $a }
if (-not $assets.ContainsKey('manifest.json')) {
    Write-Host '  X  release has no manifest.json' -ForegroundColor Red
    throw 'Release has no manifest.json'
}

$dlHeaders = @{
    'User-Agent' = 'facility-cache-client-bootstrap'
    Accept       = 'application/octet-stream'
}
if ($GitHubToken) { $dlHeaders['Authorization'] = "Bearer $GitHubToken" }

$tmp = Join-Path $env:TEMP ("facility-cache-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $manPath = Join-Path $tmp 'manifest.json'
    Invoke-WebRequest -Uri $assets['manifest.json'].url -Headers $dlHeaders -OutFile $manPath -UseBasicParsing
    $manifest = Get-Content -LiteralPath $manPath -Raw | ConvertFrom-Json
    $name = $manifest.assets.windows.name
    $expect = ([string]$manifest.assets.windows.sha256).ToLowerInvariant()
    Write-Boot "download  $name"
    $zip = Join-Path $tmp $name
    Invoke-WebRequest -Uri $assets[$name].url -Headers $dlHeaders -OutFile $zip -UseBasicParsing
    $got = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($got -ne $expect) { throw "sha256 mismatch: $got != $expect" }
    Write-Host "  +  verified  v$($manifest.version)" -ForegroundColor Green

    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    $mod = Get-ChildItem -Path $tmp -Recurse -Filter 'FacilityCache.psm1' | Select-Object -First 1
    if ($mod) {
        Import-Module $mod.FullName -Force
        Write-Boot 'gh  GitHub CLI'
        if (Sync-FacilityCacheGitHubCli) {
            Write-Host '  +  gh' -ForegroundColor Green
        } else {
            Write-Host '  !  gh install skipped — continuing on sha256 only' -ForegroundColor Yellow
        }
    }

    $ghCmd = Get-Command gh -ErrorAction SilentlyContinue
    if ($ghCmd) {
        $attested = $false
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $ghCmd.Path
            $psi.Arguments = "attestation verify `"$zip`" --repo $GitHubRepo --signer-workflow $GitHubRepo/.github/workflows/release.yml --deny-self-hosted-runners"
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            if ($GitHubToken) { $psi.EnvironmentVariables['GH_TOKEN'] = $GitHubToken }
            $proc = [System.Diagnostics.Process]::Start($psi)
            if ($proc.WaitForExit(30000)) {
                $attested = ($proc.ExitCode -eq 0)
            } else {
                $proc.Kill()
            }
        } catch {
            $attested = $false
        }
        if ($attested) {
            Write-Host "  +  attested  $name" -ForegroundColor Green
        } else {
            Write-Host '  !  attestation unavailable — continuing on sha256 only' -ForegroundColor Yellow
        }
    }

    $installer = Get-ChildItem -Path $tmp -Recurse -Filter 'Install-FacilityCache.ps1' | Select-Object -First 1
    if (-not $installer) { throw 'zip missing windows/Install-FacilityCache.ps1' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer.FullName
    if ($LASTEXITCODE -ne 0) { throw "Install-FacilityCache.ps1 exited $LASTEXITCODE" }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
