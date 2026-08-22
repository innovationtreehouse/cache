$ErrorActionPreference = 'Stop'
$dest = Join-Path $env:ProgramData 'FacilityCache\FacilityCache.psm1'
$here = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'FacilityCache.psm1'
if (Test-Path $dest) {
    Import-Module $dest -Force
} else {
    Import-Module $here -Force
}
Show-FacilityCacheDashboard
