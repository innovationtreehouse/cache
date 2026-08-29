# Scheduled-task / manual entrypoint. Runs as SYSTEM.
param(
    [switch]$Check,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'FacilityCache.psm1') -Force
Update-FacilityCacheClient -Check:$Check -Force:$Force
