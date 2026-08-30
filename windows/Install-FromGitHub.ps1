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

function Test-BootstrapAttestation {
    # Best-effort, never-throws build-provenance check on $Path — deliberately
    # duplicated here (rather than calling the same-named function the zip's
    # own FacilityCache.psm1 exports) because THIS script is verifying that
    # very zip: sourcing the checker from the archive under test would let a
    # malicious release ship a module whose Test-FacilityCacheAttestation just
    # returns $true, or omit the module entirely to skip the check. This copy
    # must run on $Path before it is ever Expand-Archive'd or Import-Module'd.
    #
    # Fetches every attestation bundle for $Path's sha256 from the PUBLIC
    # GitHub attestations API (no credentials required — a token, if
    # supplied, only lifts the 60/hr/IP unauthenticated rate limit), filters
    # to $RepoId when pinned, and verifies the rest offline as JSON Lines
    # with `gh attestation verify --bundle`, which needs no `gh auth login`.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Repo,
        [string]$Token,
        [string]$RepoId
    )
    try {
        $ghCmd = Get-Command gh -ErrorAction SilentlyContinue
        if (-not $ghCmd) { return $false }

        $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        $headers = @{
            'User-Agent' = 'facility-cache-client-bootstrap'
            Accept       = 'application/vnd.github+json'
        }
        $uri = "https://api.github.com/repos/$Repo/attestations/sha256:$hash"
        $resp = $null
        if ($Token) {
            $authHeaders = @{}
            foreach ($k in $headers.Keys) { $authHeaders[$k] = $headers[$k] }
            $authHeaders['Authorization'] = "Bearer $Token"
            try {
                $resp = Invoke-WebRequest -Uri $uri -Headers $authHeaders -UseBasicParsing -TimeoutSec 30
            } catch {
                $status = 0
                if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
                if ($status -eq 401 -or $status -eq 403) {
                    # A stale/bad token — this endpoint is public, so retry
                    # once without it rather than silently disabling this.
                    $resp = Invoke-WebRequest -Uri $uri -Headers $headers -UseBasicParsing -TimeoutSec 30
                } else {
                    throw
                }
            }
        } else {
            $resp = Invoke-WebRequest -Uri $uri -Headers $headers -UseBasicParsing -TimeoutSec 30
        }

        # Do NOT round-trip through ConvertFrom-Json/ConvertTo-Json here — it
        # corrupts the bundle (a literal U+2014 in the Rekor checkpoint gets
        # mangled). JavaScriptSerializer preserves it losslessly as long as
        # we only serialize the object graph straight out of DeserializeObject.
        Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
        $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $ser.MaxJsonLength = [int]::MaxValue
        $obj = $ser.DeserializeObject($resp.Content)
        if (-not $obj.ContainsKey('attestations') -or $obj['attestations'].Count -lt 1) { return $false }

        $lines = New-Object 'System.Collections.Generic.List[string]'
        foreach ($att in $obj['attestations']) {
            if ($RepoId -and $att.ContainsKey('repository_id') -and ([string]$att['repository_id']) -ne ([string]$RepoId)) {
                continue
            }
            if (-not $att.ContainsKey('bundle') -or $null -eq $att['bundle']) { continue }
            [void]$lines.Add($ser.Serialize($att['bundle']))
        }
        if ($lines.Count -lt 1) { return $false }
        $bundleJsonl = [string]::Join("`n", $lines.ToArray())

        $bundleFile = Join-Path $env:TEMP ("facility-cache-bootstrap-bundle-" + [guid]::NewGuid().ToString() + '.jsonl')
        try {
            # A UTF-8 BOM would break Go's JSON parser, so write UTF-8
            # without one via .NET directly rather than Set-Content, whose
            # -Encoding UTF8 always adds a BOM in PS 5.1.
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($bundleFile, $bundleJsonl, $utf8NoBom)
            # Process.Start + WaitForExit(timeout), not `&`, so a wedged gh
            # can't hang this install forever.
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $ghCmd.Path
            $psi.Arguments = "attestation verify `"$Path`" --repo $Repo --bundle `"$bundleFile`" --signer-workflow $Repo/.github/workflows/release.yml --deny-self-hosted-runners"
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $proc = [System.Diagnostics.Process]::Start($psi)
            if ($proc.WaitForExit(30000)) {
                return ($proc.ExitCode -eq 0)
            } else {
                $proc.Kill()
                return $false
            }
        } finally {
            Remove-Item -LiteralPath $bundleFile -Force -ErrorAction SilentlyContinue
        }
    } catch {
        return $false
    }
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

    # Attest BEFORE the zip is ever extracted or its module imported: the
    # verdict on this archive must never come from code contained in that
    # same archive. If `gh` isn't already on this machine, there is nothing
    # trustworthy to attest with yet — skip quietly here rather than warning,
    # and let the later gh-install step's own message cover that case.
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        Write-Boot 'attest  build provenance'
        if (Test-BootstrapAttestation -Path $zip -Repo $GitHubRepo -Token $GitHubToken -RepoId $GitHubRepoId) {
            Write-Host "  +  attested  $name" -ForegroundColor Green
        } else {
            Write-Host '  !  attestation unavailable — continuing on sha256 only' -ForegroundColor Yellow
        }
    }

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

    $installer = Get-ChildItem -Path $tmp -Recurse -Filter 'Install-FacilityCache.ps1' | Select-Object -First 1
    if (-not $installer) { throw 'zip missing windows/Install-FacilityCache.ps1' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer.FullName
    if ($LASTEXITCODE -ne 0) { throw "Install-FacilityCache.ps1 exited $LASTEXITCODE" }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
