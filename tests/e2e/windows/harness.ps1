# Windows client end-to-end harness. Windows PowerShell 5.1, must run ELEVATED
# (a Windows container's ContainerAdministrator qualifies). Exercises the real
# install / apply / update / uninstall flows including scheduled tasks, HKLM
# and machine-scope environment variables — run only on a throwaway machine.
param(
    [Parameter(Mandatory = $true)][string]$CacheHost,
    [Parameter(Mandatory = $true)][string]$ExpectedIp,
    [Parameter(Mandatory = $true)][string]$RepoRoot
)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$script:pass = 0; $script:fail = 0
function Check([string]$name, [bool]$cond, [string]$detail = '') {
    if ($cond) { $script:pass++; Write-Host "PASS  $name  $detail" } else { $script:fail++; Write-Host "FAIL  $name  $detail" }
}
function Section($t) { Write-Host ''; Write-Host "##### $t" }
function Get-MachineEnvVar([string]$n) { [Environment]::GetEnvironmentVariable($n, 'Machine') }
function Write-FcConfig($extra) {
    $cfg = @{ CacheHost = $CacheHost; ExpectedIp = $ExpectedIp }
    if ($extra) { foreach ($k in $extra.Keys) { $cfg[$k] = $extra[$k] } }
    $cfg | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $env:ProgramData 'FacilityCache\config.json') -Encoding ASCII
}

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$admin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Section 'T0 environment'
Check 'elevated' $admin "$($id.Name)"
if (-not $admin) { Write-Host 'RESULT pass=0 fail=1 (not elevated)'; exit 1 }
try { Start-Service Schedule -ErrorAction SilentlyContinue } catch { }
$ips = [System.Net.Dns]::GetHostAddresses($CacheHost) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object ToString
Check "CacheHost resolves to ExpectedIp" ($ips -contains $ExpectedIp) ($ips -join ',')
$tcp = New-Object Net.Sockets.TcpClient; $iar = $tcp.BeginConnect($ExpectedIp, 3141, $null, $null)
Check 'cache port 3141 reachable' ($iar.AsyncWaitHandle.WaitOne(3000) -and ($tcp.Connected)); $tcp.Close()

Section 'T1 install (real scheduled tasks, HKLM, machine env)'
New-Item -ItemType Directory -Force -Path (Join-Path $env:ProgramData 'FacilityCache') | Out-Null
Write-FcConfig $null
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'windows\Install-FacilityCache.ps1') -NoRestartDocker
Check 'installer exit 0' ($LASTEXITCODE -eq 0) "exit=$LASTEXITCODE"
foreach ($f in 'FacilityCache.psm1', 'FacilityCache-Apply.ps1', 'FacilityCache-Update.ps1', 'VERSION', 'defaults.json') {
    Check "installed: $f" (Test-Path (Join-Path $env:ProgramData "FacilityCache\$f"))
}
Check 'task FacilityCache-Apply registered' ([bool](Get-ScheduledTask -TaskName 'FacilityCache-Apply' -ErrorAction SilentlyContinue))
Check 'task FacilityCache-Update registered' ([bool](Get-ScheduledTask -TaskName 'FacilityCache-Update' -ErrorAction SilentlyContinue))
$do = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' -ErrorAction SilentlyContinue
Check 'DO: DOCacheHostSource=2, no static host' ($do.DOCacheHostSource -eq 2 -and -not $do.DOCacheHost)
Check 'machine env PIP_INDEX_URL set' ((Get-MachineEnvVar 'PIP_INDEX_URL') -eq "http://${CacheHost}:3141/root/pypi/+simple/") (Get-MachineEnvVar 'PIP_INDEX_URL')
Check 'machine env UV_INSECURE_HOST set' ((Get-MachineEnvVar 'UV_INSECURE_HOST') -eq $CacheHost)
Check 'pip.ini written' (Test-Path (Join-Path $env:ProgramData 'pip\pip.ini'))
Check 'uv.toml written' (Test-Path (Join-Path $env:ProgramData 'uv\uv.toml'))
$dj = Join-Path $env:ProgramData 'Docker\config\daemon.json'
$djOk = $false
if (Test-Path $dj) {
    $j = Get-Content $dj -Raw | ConvertFrom-Json
    $djOk = ($j.'registry-mirrors' -contains "http://${CacheHost}:5000") -and ($j.'insecure-registries' -contains "${CacheHost}:5001")
}
Check 'daemon.json mirrors written' $djOk

Section 'T2 status + module probes (on-site)'
Import-Module (Join-Path $env:ProgramData 'FacilityCache\FacilityCache.psm1') -Force
$st = Get-FacilityCacheStatus
Check 'DnsOk' $st.DnsOk "resolved=$($st.Resolved)"
Check 'pypi port on' ([bool]$st.Ports['pypi'])
Check 'npm port on' ([bool]$st.Ports['npm'])
Show-FacilityCacheDashboard
$r = Invoke-WebRequest -UseBasicParsing -Uri (Get-MachineEnvVar 'PIP_INDEX_URL') -TimeoutSec 10
Check 'pip index URL served by fake cache' ($r.StatusCode -eq 200)

Section 'T3 wrong address (negative)'
Write-FcConfig @{ ExpectedIp = '10.9.9.9' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $env:ProgramData 'FacilityCache\FacilityCache-Apply.ps1')
Check 'apply exit 0' ($LASTEXITCODE -eq 0)
Check 'pip.ini removed' (-not (Test-Path (Join-Path $env:ProgramData 'pip\pip.ini')))
Check 'machine env cleared' (-not (Get-MachineEnvVar 'PIP_INDEX_URL'))
Import-Module (Join-Path $env:ProgramData 'FacilityCache\FacilityCache.psm1') -Force
Check 'status: wrong address' ((Get-FacilityCacheStatus).DnsOk -eq $false)

Section 'T4 off-site NXDOMAIN (negative)'
Write-FcConfig @{ CacheHost = 'cache.nonexistent-offsite.invalid' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $env:ProgramData 'FacilityCache\FacilityCache-Apply.ps1')
Check 'apply exit 0' ($LASTEXITCODE -eq 0)
Check 'uv.toml removed' (-not (Test-Path (Join-Path $env:ProgramData 'uv\uv.toml')))

Section 'T5 back on-site; foreign file protection'
Write-FcConfig $null
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $env:ProgramData 'FacilityCache\FacilityCache-Apply.ps1')
Check 'drop-ins re-applied' (Test-Path (Join-Path $env:ProgramData 'pip\pip.ini'))
'# not ours' | Set-Content (Join-Path $env:ProgramData 'pip\pip.ini') -Encoding ASCII
Write-FcConfig @{ CacheHost = 'cache.nonexistent-offsite.invalid' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $env:ProgramData 'FacilityCache\FacilityCache-Apply.ps1')
Check 'foreign pip.ini left alone off-site' (Test-Path (Join-Path $env:ProgramData 'pip\pip.ini'))
Remove-Item (Join-Path $env:ProgramData 'pip\pip.ini') -Force
Write-FcConfig $null

Section 'T6 update: -Check, repo-id pin refusal (negative), full update (real GitHub + attestation)'
'1.0.0' | Set-Content (Join-Path $env:ProgramData 'FacilityCache\VERSION') -Encoding ASCII
& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Module '$env:ProgramData\FacilityCache\FacilityCache.psm1'; Update-FacilityCacheClient -Check" | Tee-Object -Variable chk | Out-Host
Check 'update -Check exit 0' ($LASTEXITCODE -eq 0)
Check 'reports update available' ([bool]($chk -match 'update available'))
Write-FcConfig @{ GitHubRepoId = 999 }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Module '$env:ProgramData\FacilityCache\FacilityCache.psm1'; Update-FacilityCacheClient -Check" | Out-Host
Check 'repo-id pin mismatch refuses (nonzero exit)' ($LASTEXITCODE -ne 0)
Write-FcConfig $null
& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Module '$env:ProgramData\FacilityCache\FacilityCache.psm1'; Update-FacilityCacheClient" | Tee-Object -Variable upd | Out-Host
$updExit = $LASTEXITCODE
Check 'attestation verified during update' ([bool]($upd -match 'verified'))
$state = Get-Content (Join-Path $env:ProgramData 'FacilityCache\state.json') -Raw | ConvertFrom-Json
$v = (Get-Content (Join-Path $env:ProgramData 'FacilityCache\VERSION') -Raw).Trim()
# The update installs the LATEST published release. Releases up to v1.0.1 ship
# an installer with the daemon.json PS 5.1 crash, so until a newer release is
# published the honest outcome is a surfaced failure. Accept either: a clean
# update (state=updated, VERSION advanced) or a truthfully recorded failure.
if ($state.last_result -eq 'updated') {
    Check 'full update: clean (state=updated, VERSION advanced)' ($updExit -eq 0 -and $v -ne '1.0.0') "now $v"
} else {
    # No VERSION assertion here: the released installer copies files (VERSION
    # included) before the step it crashes on, so a failed install can still
    # advance the VERSION file. What matters is that the failure is surfaced.
    Check 'full update: released-installer failure surfaced honestly (pre-fix release)' ($updExit -ne 0 -and $state.last_result -like 'update failed:*') $state.last_result
}
Check 'update re-registered tasks' ([bool](Get-ScheduledTask -TaskName 'FacilityCache-Apply' -ErrorAction SilentlyContinue))

Section 'T7 uninstall'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $env:ProgramData 'FacilityCache\Uninstall-FacilityCache.ps1')
Check 'uninstall exit 0' ($LASTEXITCODE -eq 0)
Check 'tasks unregistered' (-not (Get-ScheduledTask -TaskName 'FacilityCache-Apply' -ErrorAction SilentlyContinue) -and -not (Get-ScheduledTask -TaskName 'FacilityCache-Update' -ErrorAction SilentlyContinue))
$do2 = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' -ErrorAction SilentlyContinue
Check 'DO policy removed' (-not $do2 -or -not $do2.PSObject.Properties['DOCacheHostSource'])
Check 'machine env cleared' (-not (Get-MachineEnvVar 'PIP_INDEX_URL') -and -not (Get-MachineEnvVar 'NPM_CONFIG_REGISTRY'))
Check 'module removed' (-not (Test-Path (Join-Path $env:ProgramData 'FacilityCache\FacilityCache.psm1')))
Check 'config.json kept' (Test-Path (Join-Path $env:ProgramData 'FacilityCache\config.json'))
Check 'logs kept' (Test-Path (Join-Path $env:ProgramData 'FacilityCache\logs'))

Write-Host ''
Write-Host "RESULT pass=$($script:pass) fail=$($script:fail)"
exit $script:fail
