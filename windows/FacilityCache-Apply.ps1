# Scheduled-task entrypoint. Runs as SYSTEM.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'FacilityCache.psm1') -Force
Invoke-FacilityCacheApply
