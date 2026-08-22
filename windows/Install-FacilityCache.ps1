#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Install facility cache client settings on Windows.

.DESCRIPTION
  - Delivery Optimization: DHCP option 235 only (no static cache host)
  - Docker Hub registry-mirrors (engine falls back to docker.io off-site)
  - pip / uv / npm: enabled only while cache.facility.innovationtreehouse.org
    resolves to 192.168.1.200 and the service port answers
#>
[CmdletBinding()]
param(
    [switch]$NoDocker,
    [switch]$NoRestartDocker
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$dest = Join-Path $env:ProgramData 'FacilityCache'
Import-Module (Join-Path $here 'FacilityCache.psm1') -Force
$script:FcStepN = 6
$verFile = Join-Path $root 'VERSION'
$ver = 'unknown'
if (Test-Path $verFile) { $ver = (Get-Content $verFile -Raw).Trim() }
Write-FcHeader 'facility-cache-client' "install  v$ver"

Write-FcStep 'files' 'copying into ProgramData'
New-Item -ItemType Directory -Path $dest -Force | Out-Null
foreach ($name in @(
    'FacilityCache.psm1',
    'FacilityCache-Apply.ps1',
    'FacilityCache-Update.ps1',
    'Install-FacilityCache.ps1',
    'Status-FacilityCache.ps1',
    'Uninstall-FacilityCache.ps1'
)) {
    $src = Join-Path $here $name
    if (Test-Path $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $dest $name) -Force
    }
}
foreach ($name in @('VERSION', 'defaults.json')) {
    $src = Join-Path $root $name
    if (Test-Path $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $dest $name) -Force
    }
}

$cfgPath = Join-Path $dest 'config.json'
if (-not (Test-Path $cfgPath)) {
    '{}' | Set-Content -LiteralPath $cfgPath -Encoding ASCII
}
Write-FcStepOk "v$ver -> $dest"
Import-Module (Join-Path $dest 'FacilityCache.psm1') -Force

Write-FcStep 'delivery-opt' 'DHCP option 235'
Set-DeliveryOptimizationDhcpDiscovery
Write-FcStepOk 'DOCacheHostSource=2 (no static host)'

Write-FcStep 'docker' 'registry-mirrors'
if (-not $NoDocker) {
    $changed = Merge-DockerDaemonJson
    if ($changed) {
        if (-not $NoRestartDocker) {
            $svc = Get-Service -Name 'docker' -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running') {
                Restart-Service docker
                Write-FcStepOk 'mirrors written · docker restarted'
            } else {
                Write-FcStepOk 'mirrors written · restart Docker Desktop if you use it'
            }
        } else {
            Write-FcStepOk 'mirrors written · restart docker when convenient'
        }
    } else {
        Write-FcStepOk 'already configured (or Docker not installed)'
    }
} else {
    Write-Host '  skipped --NoDocker' -ForegroundColor DarkGray
}

Write-FcStep 'apply' 'LAN drop-ins'
Invoke-FacilityCacheApply
Write-FcStepOk 'pip/npm/uv follow the facility LAN'

Write-FcStep 'tasks' 'apply + update'
$taskName = 'FacilityCache-Apply'
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

$arg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$(Join-Path $dest 'FacilityCache-Apply.ps1')`""
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$triggers = @(
    (New-ScheduledTaskTrigger -AtStartup),
    $repeat
)

try {
    $eventXml = @'
<QueryList>
  <Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational">
    <Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[(EventID=10000 or EventID=10001)]]</Select>
  </Query>
</QueryList>
'@
    $eventClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace root/Microsoft/Windows/TaskScheduler
    $cimTrigger = New-CimInstance -CimClass $eventClass -ClientOnly
    $cimTrigger.Enabled = $true
    $cimTrigger.Subscription = $eventXml
    $triggers += $cimTrigger
} catch {
    Write-Host 'Could not register a network-change trigger; using boot + 5-minute timer only.'
}

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Principal $principal `
    -Description 'Enable Innovation Treehouse cache drop-ins only on the facility LAN' | Out-Null

$updateName = 'FacilityCache-Update'
Unregister-ScheduledTask -TaskName $updateName -Confirm:$false -ErrorAction SilentlyContinue
$updateArg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$(Join-Path $dest 'FacilityCache-Update.ps1')`""
$updateAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $updateArg
$updateDaily = New-ScheduledTaskTrigger -Daily -At 3:17am
$updateDaily.RandomDelay = (New-TimeSpan -Minutes 30)
$updateTriggers = @(
    (New-ScheduledTaskTrigger -AtStartup),
    $updateDaily
)
Register-ScheduledTask -TaskName $updateName -Action $updateAction -Trigger $updateTriggers -Principal $principal `
    -Description 'Install newer facility-cache-client GitHub Releases' | Out-Null
Write-FcStepOk 'FacilityCache-Apply 5m · FacilityCache-Update daily'

Write-FcFinish -Ok $true -Message "v$ver ready"
Write-FcNote 'Status-FacilityCache.ps1     dashboard'
Write-FcNote 'FacilityCache-Update.ps1     GitHub Releases'
Write-FcNote 'Show-FacilityCacheLog        fetchable event log'
