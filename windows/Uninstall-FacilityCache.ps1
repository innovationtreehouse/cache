#Requires -RunAsAdministrator
[CmdletBinding()]
param([switch]$KeepDocker)

$ErrorActionPreference = 'Stop'
$dest = Join-Path $env:ProgramData 'FacilityCache'
$module = Join-Path $dest 'FacilityCache.psm1'
if (Test-Path $module) {
    Import-Module $module -Force
    Write-FcHeader 'facility-cache-client' 'uninstall'
    $script:FcStepN = 4
    Write-FcStep 'policy' 'Delivery Optimization'
    Remove-DeliveryOptimizationDhcpDiscovery
    Write-FcStepOk 'DOCacheHostSource removed'
    Write-FcStep 'docker' 'registry-mirrors'
    if (-not $KeepDocker) {
        Remove-DockerMirrors
        Write-FcStepOk 'facility mirrors stripped'
    } else {
        Write-FcStepOk 'kept (-KeepDocker)'
    }
} else {
    Write-Host '  facility-cache-client  uninstall' -ForegroundColor Cyan
}

if (-not (Get-Command Write-FcStep -ErrorAction SilentlyContinue)) {
    function Write-FcStep { param($Name, $Message = '') Write-Host "  * $Name  $Message" }
    function Write-FcStepOk { param($Message = 'done') Write-Host "  + $Message" -ForegroundColor Green }
    function Write-FcFinish { param([bool]$Ok = $true, [string]$Message = '') Write-Host "  $Message" }
    function Write-FcNote { param($Message) Write-Host "    $Message" -ForegroundColor DarkGray }
}

Write-FcStep 'tasks' 'scheduled tasks'
Unregister-ScheduledTask -TaskName 'FacilityCache-Apply' -Confirm:$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'FacilityCache-Update' -Confirm:$false -ErrorAction SilentlyContinue
Write-FcStepOk 'Apply + Update unregistered'

foreach ($name in @(
    'PIP_INDEX_URL', 'PIP_TRUSTED_HOST', 'UV_INDEX_URL', 'UV_INSECURE_HOST', 'NPM_CONFIG_REGISTRY'
)) {
    [Environment]::SetEnvironmentVariable($name, $null, 'Machine')
}

foreach ($path in @(
    (Join-Path $env:ProgramData 'pip\pip.ini'),
    (Join-Path $env:ProgramData 'uv\uv.toml')
)) {
    if (Test-Path $path) {
        $head = Get-Content -LiteralPath $path -TotalCount 2 -ErrorAction SilentlyContinue
        if ($head -match 'facility-cache-managed') {
            Remove-Item -LiteralPath $path -Force
        }
    }
}

$npmCmd = Get-Command npm -ErrorAction SilentlyContinue
if ($npmCmd) {
    & npm config delete registry --location=global 2>$null
}

$logHint = $null
if (Get-Command Get-FacilityCacheLogPath -ErrorAction SilentlyContinue) {
    $logHint = Get-FacilityCacheLogPath
}

Write-FcStep 'files' $dest
if (Test-Path $dest) {
    Remove-Item -LiteralPath $dest -Recurse -Force
}
Write-FcStepOk 'ProgramData client removed'

if (Get-Command Write-FcFinish -ErrorAction SilentlyContinue) {
    Write-FcFinish -Ok $true -Message 'uninstalled'
    if ($logHint) { Write-FcNote "logs remain at $logHint until that folder is deleted" }
} else {
    Write-Host 'Uninstalled facility-cache client.'
}
