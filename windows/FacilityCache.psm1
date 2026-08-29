# Facility cache client helpers. Windows PowerShell 5.1 compatible.

$script:DefaultConfig = @{
    CacheHost        = 'cache.facility.innovationtreehouse.org'
    ExpectedIp       = '10.41.1.50'
    AptPort          = 3142
    PypiPort         = 3141
    NpmPort          = 4873
    DockerHubPort    = 5000
    DockerGhcrPort   = 5001
    ProbeTimeoutMs   = 1000
    GitHubRepo       = 'innovationtreehouse/cache'
    GitHubRepoId     = 1343160243
    AutoUpdate       = $true
}

function Merge-FacilityCacheObject {
    param($Cfg, $Obj)
    if ($null -eq $Obj) { return }
    $Obj.PSObject.Properties | ForEach-Object {
        $Cfg[$_.Name] = $_.Value
    }
}

function Get-FacilityCacheInstallDir {
    return (Join-Path $env:ProgramData 'FacilityCache')
}

$script:FcCmd = ''
$script:FcStepI = 0
$script:FcStepN = 0
$script:FcOk = [string][char]0x2713
$script:FcFail = [string][char]0x2717
$script:FcWork = [string][char]0x25CF
$script:FcOff = [string][char]0x25CB

function Get-FacilityCacheLogPath {
    $dir = Join-Path (Get-FacilityCacheInstallDir) 'logs'
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return (Join-Path $dir 'client.jsonl')
}

function Write-FacilityCacheLog {
    param(
        [string]$Level = 'info',
        [string]$Event = 'info',
        [string]$Message,
        $Extra = $null
    )
    $rec = @{
        ts    = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        level = $Level
        cmd   = $script:FcCmd
        event = $Event
        msg   = $Message
        extra = $Extra
    }
    try {
        $path = Get-FacilityCacheLogPath
        ($rec | ConvertTo-Json -Compress -Depth 6) | Add-Content -LiteralPath $path -Encoding UTF8
        if ((Get-Item $path).Length -gt 2000000) {
            $bak = "$path.1"
            if (Test-Path $bak) { Remove-Item $bak -Force }
            Move-Item $path $bak
        }
    } catch { }
}

function Write-FcHeader {
    param([string]$Title, [string]$Subtitle = '')
    $script:FcCmd = $Title
    Write-Host ''
    Write-Host -NoNewline '  '
    Write-Host -NoNewline $Title -ForegroundColor Cyan
    if ($Subtitle) {
        Write-Host -NoNewline "  $Subtitle" -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host ('  ' + ('-' * 48)) -ForegroundColor DarkGray
    Write-FacilityCacheLog -Level info -Event start -Message "$Title $Subtitle"
}

function Write-FcKv {
    param([string]$Key, [string]$Value, [string]$Kind = '')
    $mark = ''
    $color = 'Gray'
    switch ($Kind) {
        'ok'   { $mark = " $($script:FcOk)"; $color = 'Green' }
        'fail' { $mark = " $($script:FcFail)"; $color = 'Red' }
        'warn' { $mark = ' !'; $color = 'Yellow' }
        'on'   { $mark = " $($script:FcWork)"; $color = 'Green' }
        'off'  { $mark = " $($script:FcOff)"; $color = 'DarkGray' }
        'work' { $mark = " $($script:FcWork)"; $color = 'Cyan' }
    }
    Write-Host -NoNewline '  '
    Write-Host -NoNewline ('{0,-12}' -f $Key) -ForegroundColor DarkGray
    Write-Host -NoNewline " $Value"
    if ($mark) { Write-Host $mark -ForegroundColor $color } else { Write-Host '' }
}

function Write-FcOk   { param([string]$Message) Write-Host "  $($script:FcOk) $Message" -ForegroundColor Green; Write-FacilityCacheLog -Event ok -Message $Message }
function Write-FcFail { param([string]$Message) Write-Host "  $($script:FcFail) $Message" -ForegroundColor Red; Write-FacilityCacheLog -Level error -Event fail -Message $Message }
function Write-FcWarn { param([string]$Message) Write-Host "  ! $Message" -ForegroundColor Yellow; Write-FacilityCacheLog -Level warn -Event warn -Message $Message }
function Write-FcNote { param([string]$Message) Write-Host "    $Message" -ForegroundColor DarkGray }

function Write-FcStep {
    param([string]$Name, [string]$Message = '')
    $script:FcStepI++
    $prefix = ''
    if ($script:FcStepN -gt 0) { $prefix = "$($script:FcStepI)/$($script:FcStepN)  " }
    Write-Host "  $($script:FcWork) $prefix$Name  $Message" -ForegroundColor Cyan
    Write-FacilityCacheLog -Event step_start -Message "$Name $Message"
}

function Write-FcStepOk {
    param([string]$Message = 'done')
    Write-Host "  $($script:FcOk) $Message" -ForegroundColor Green
    Write-FacilityCacheLog -Event step_ok -Message $Message
}

function Write-FcBar {
    param([int]$Current, [int]$Total, [string]$Label = '')
    if ($Total -le 0) { $Total = 1 }
    $pct = [Math]::Min(100, [int]($Current * 100 / $Total))
    Write-Progress -Activity 'facility-cache' -Status $Label -PercentComplete $pct
    $width = 24
    $filled = [int]($width * $pct / 100)
    $bar = ('#' * $filled) + ('-' * ($width - $filled))
    Write-Host -NoNewline "`r  $($script:FcWork) $bar  $pct%  $Label   "
    if ($Current -ge $Total) {
        Write-Host ''
        Write-Progress -Activity 'facility-cache' -Completed
    }
}

function Write-FcFinish {
    param([bool]$Ok = $true, [string]$Message = '')
    Write-Host ('  ' + ('-' * 48)) -ForegroundColor DarkGray
    if ($Ok) {
        if (-not $Message) { $Message = 'done' }
        Write-Host "  $($script:FcOk) $Message" -ForegroundColor Green
    } else {
        if (-not $Message) { $Message = 'failed' }
        Write-Host "  $($script:FcFail) $Message" -ForegroundColor Red
    }
    Write-Host "    log $(Get-FacilityCacheLogPath)" -ForegroundColor DarkGray
    Write-Host ''
    Write-FacilityCacheLog -Event finish -Message $Message -Extra @{ ok = $Ok }
}

function Show-FacilityCacheLog {
    param(
        [int]$Count = 40,
        [switch]$Follow,
        [switch]$Json,
        [switch]$PathOnly
    )
    $path = Get-FacilityCacheLogPath
    if ($PathOnly) { Write-Output $path; return }
    if (-not (Test-Path $path)) {
        Write-FcWarn "no log yet at $path"
        return
    }
    if ($Json -and -not $Follow) {
        Get-Content -LiteralPath $path
        return
    }
    Write-FcHeader 'facility-cache log' $path
    $emit = {
        param($line)
        if (-not $line) { return }
        if ($Json) { Write-Output $line; return }
        try { $rec = $line | ConvertFrom-Json } catch { Write-Host "  $line"; return }
        $ts = ([string]$rec.ts)
        if ($ts.Length -ge 19) { $ts = $ts.Substring(11, 8) }
        $color = 'Cyan'
        $mark = $script:FcWork
        if ($rec.level -eq 'error') { $color = 'Red'; $mark = $script:FcFail }
        elseif ($rec.level -eq 'warn') { $color = 'Yellow'; $mark = '!' }
        elseif ($rec.event -in @('ok', 'step_ok', 'finish')) { $color = 'Green'; $mark = $script:FcOk }
        Write-Host -NoNewline "  $mark " -ForegroundColor $color
        Write-Host -NoNewline "$ts  $($rec.cmd)  " -ForegroundColor DarkGray
        Write-Host $rec.msg
    }
    Get-Content -LiteralPath $path -Tail $Count | ForEach-Object { & $emit $_ }
    if ($Follow) {
        Write-Host '  following  Ctrl-C to stop' -ForegroundColor DarkGray
        Get-Content -LiteralPath $path -Wait -Tail 0 | ForEach-Object { & $emit $_ }
    }
}

function Show-FacilityCacheDashboard {
    $st = Get-FacilityCacheStatus
    Write-FcHeader 'facility-cache-client' ("v" + $st.Version)
    $net = 'off-site'
    $kind = 'off'
    if ($st.DnsOk) { $net = 'on-site'; $kind = 'on' }
    elseif ($st.Resolved) { $net = 'wrong address'; $kind = 'fail' }
    Write-FcKv 'network' $net $kind
    Write-FcKv 'host' $st.Host
    Write-FcKv 'expect' $st.ExpectedIp
    $resKind = 'fail'
    if ($st.DnsOk) { $resKind = 'ok' }
    Write-FcKv 'resolved' $(if ($st.Resolved) { $st.Resolved } else { 'none' }) $resKind
    Write-Host ''
    foreach ($name in @('apt', 'pypi', 'npm', 'dockerhub', 'ghcr')) {
        $open = [bool]$st.Ports[$name]
        $label = $(if ($open) { 'on ' } else { 'off' })
        $kind = $(if ($open) { 'on' } else { 'off' })
        Write-FcKv $name $label $kind
    }
    Write-Host ''
    Write-FcKv 'updates' $(if ($st.AutoUpdate) { 'auto on' } else { 'auto off' }) $(if ($st.AutoUpdate) { 'on' } else { 'off' })
    Write-FcKv 'repo' $st.GitHubRepo
    $last = 'never'
    if ($st.Update) {
        $last = "$($st.Update.last_result)  $($st.Update.latest_version)  $($st.Update.updated_at)"
    }
    Write-FcKv 'last' $last
    Write-FcKv 'log' (Get-FacilityCacheLogPath)
    Write-Host ''
}

function Get-FacilityCacheConfig {
    $dir = Get-FacilityCacheInstallDir
    $cfg = $script:DefaultConfig.Clone()
    $defaultsPath = Join-Path $dir 'defaults.json'
    $cfgPath = Join-Path $dir 'config.json'
    if (Test-Path $defaultsPath) {
        Merge-FacilityCacheObject -Cfg $cfg -Obj (Get-Content -LiteralPath $defaultsPath -Raw | ConvertFrom-Json)
    }
    if (Test-Path $cfgPath) {
        Merge-FacilityCacheObject -Cfg $cfg -Obj (Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json)
    }
    $tokenFile = Join-Path $dir 'github-token'
    if (Test-Path $tokenFile) {
        $cfg['GitHubToken'] = (Get-Content -LiteralPath $tokenFile -Raw).Trim()
    }
    if ($env:GITHUB_TOKEN) { $cfg['GitHubToken'] = $env:GITHUB_TOKEN }
    return $cfg
}

function Get-FacilityCacheInstalledVersion {
    $path = Join-Path (Get-FacilityCacheInstallDir) 'VERSION'
    if (Test-Path $path) {
        return ((Get-Content -LiteralPath $path -Raw).Trim().TrimStart('v'))
    }
    return '0.0.0'
}

function Get-FacilityCacheIPv4 {
    param([string]$HostName)
    try {
        return [System.Net.Dns]::GetHostAddresses($HostName) |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
            ForEach-Object { $_.ToString() }
    } catch {
        return @()
    }
}

function Test-FacilityCachePort {
    param(
        [Parameter(Mandatory = $true)][string]$Ip,
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutMs = 1000
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($Ip, $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if (-not $ok) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Test-FacilityCache {
    param([int]$Port = 0)
    $cfg = Get-FacilityCacheConfig
    $ips = @(Get-FacilityCacheIPv4 -HostName $cfg.CacheHost)
    $dnsOk = $ips -contains [string]$cfg.ExpectedIp
    if (-not $dnsOk) { return $false }
    if ($Port -gt 0) {
        return (Test-FacilityCachePort -Ip $cfg.ExpectedIp -Port $Port -TimeoutMs $cfg.ProbeTimeoutMs)
    }
    return $true
}

function Get-FacilityCacheStatus {
    $cfg = Get-FacilityCacheConfig
    $ips = @(Get-FacilityCacheIPv4 -HostName $cfg.CacheHost)
    $dnsOk = $ips -contains [string]$cfg.ExpectedIp
    $ports = @{
        apt       = $cfg.AptPort
        pypi      = $cfg.PypiPort
        npm       = $cfg.NpmPort
        dockerhub = $cfg.DockerHubPort
        ghcr      = $cfg.DockerGhcrPort
    }
    $open = @{}
    foreach ($name in $ports.Keys) {
        $open[$name] = $false
        if ($dnsOk) {
            $open[$name] = Test-FacilityCachePort -Ip $cfg.ExpectedIp -Port $ports[$name] -TimeoutMs $cfg.ProbeTimeoutMs
        }
    }
    $state = $null
    $statePath = Join-Path (Get-FacilityCacheInstallDir) 'state.json'
    if (Test-Path $statePath) {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    }
    [pscustomobject]@{
        Host       = $cfg.CacheHost
        ExpectedIp = $cfg.ExpectedIp
        Resolved   = ($ips -join ',')
        DnsOk      = $dnsOk
        Ports      = $open
        Version    = Get-FacilityCacheInstalledVersion
        GitHubRepo = $cfg.GitHubRepo
        AutoUpdate = $cfg.AutoUpdate
        Update     = $state
    }
}

function Set-MachineEnv {
    param([string]$Name, [string]$Value)
    $target = if ($null -eq $Value -or $Value -eq '') { $null } else { $Value }
    $current = [Environment]::GetEnvironmentVariable($Name, 'Machine')
    if ($current -eq $target) { return }
    # SetEnvironmentVariable(..., 'Machine') broadcasts WM_SETTINGCHANGE to every top-level
    # window; only call it when the value actually changes (this runs every 5 minutes).
    [Environment]::SetEnvironmentVariable($Name, $target, 'Machine')
}

function Write-ManagedFile {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Set-Content -LiteralPath $Path -Value $Content -Encoding ASCII
}

function Remove-ManagedFile {
    param([string]$Path)
    if (Test-Path $Path) {
        $head = Get-Content -LiteralPath $Path -TotalCount 2 -ErrorAction SilentlyContinue
        if ($head -match 'facility-cache-managed') {
            Remove-Item -LiteralPath $Path -Force
        }
    }
}

function Merge-DockerDaemonJson {
    Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $paths = @(
        (Join-Path $env:ProgramData 'Docker\config\daemon.json'),
        (Join-Path $env:USERPROFILE '.docker\daemon.json')
    )
    $cfg = Get-FacilityCacheConfig
    $mirror = "http://$($cfg.CacheHost):$($cfg.DockerHubPort)"
    $insecureWanted = @(
        "$($cfg.CacheHost):$($cfg.DockerHubPort)",
        "$($cfg.CacheHost):$($cfg.DockerGhcrPort)"
    )
    $changed = $false
    foreach ($path in $paths) {
        $dir = Split-Path -Parent $path
        $exists = Test-Path $path
        if (-not $exists -and $path -like '*\.docker\*') { continue }
        if (-not (Test-Path $dir)) {
            if ($path -like '*\Docker\config\*') {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            } else {
                continue
            }
        }
        $hash = New-Object 'System.Collections.Generic.Dictionary[string,object]'
        if ($exists) {
            $raw = Get-Content -LiteralPath $path -Raw
            if ($raw -and $raw.Trim()) {
                $loaded = $ser.DeserializeObject($raw)
                foreach ($key in $loaded.Keys) { $hash[$key] = $loaded[$key] }
            }
        }
        $mirrors = New-Object 'System.Collections.Generic.List[object]'
        if ($hash.ContainsKey('registry-mirrors') -and $null -ne $hash['registry-mirrors']) {
            foreach ($m in @($hash['registry-mirrors'])) { [void]$mirrors.Add($m) }
        }
        if (-not $mirrors.Contains($mirror)) { $mirrors.Insert(0, $mirror) }
        $regs = New-Object 'System.Collections.Generic.List[object]'
        if ($hash.ContainsKey('insecure-registries') -and $null -ne $hash['insecure-registries']) {
            foreach ($r in @($hash['insecure-registries'])) { [void]$regs.Add($r) }
        }
        foreach ($item in $insecureWanted) {
            if (-not $regs.Contains($item)) { [void]$regs.Add($item) }
        }
        $hash['registry-mirrors'] = $mirrors
        $hash['insecure-registries'] = $regs
        $json = $ser.Serialize($hash)
        $old = ''
        if ($exists) { $old = (Get-Content -LiteralPath $path -Raw).Trim() }
        if ($json -ne $old) {
            $bak = "$path.facility-cache.bak"
            if ($exists -and -not (Test-Path $bak)) { Copy-Item $path $bak }
            Set-Content -LiteralPath $path -Value $json -Encoding UTF8
            $changed = $true
        }
    }
    return $changed
}

function Remove-DockerMirrors {
    Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $paths = @(
        (Join-Path $env:ProgramData 'Docker\config\daemon.json'),
        (Join-Path $env:USERPROFILE '.docker\daemon.json')
    )
    $cfg = Get-FacilityCacheConfig
    $mirror = "http://$($cfg.CacheHost):$($cfg.DockerHubPort)"
    $insecure = @(
        "$($cfg.CacheHost):$($cfg.DockerHubPort)",
        "$($cfg.CacheHost):$($cfg.DockerGhcrPort)"
    )
    foreach ($path in $paths) {
        if (-not (Test-Path $path)) { continue }
        $raw = Get-Content -LiteralPath $path -Raw
        if (-not $raw -or -not $raw.Trim()) { continue }
        $loaded = $ser.DeserializeObject($raw)
        $hash = New-Object 'System.Collections.Generic.Dictionary[string,object]'
        foreach ($key in $loaded.Keys) { $hash[$key] = $loaded[$key] }
        if ($hash.ContainsKey('registry-mirrors')) {
            $kept = New-Object 'System.Collections.Generic.List[object]'
            foreach ($m in @($hash['registry-mirrors'])) {
                if ($m -ne $mirror) { [void]$kept.Add($m) }
            }
            if ($kept.Count -gt 0) { $hash['registry-mirrors'] = $kept } else { [void]$hash.Remove('registry-mirrors') }
        }
        if ($hash.ContainsKey('insecure-registries')) {
            $kept = New-Object 'System.Collections.Generic.List[object]'
            foreach ($r in @($hash['insecure-registries'])) {
                if ($insecure -notcontains $r) { [void]$kept.Add($r) }
            }
            if ($kept.Count -gt 0) { $hash['insecure-registries'] = $kept } else { [void]$hash.Remove('insecure-registries') }
        }
        if ($hash.Count -eq 0) {
            Remove-Item -LiteralPath $path -Force
        } else {
            Set-Content -LiteralPath $path -Value $ser.Serialize($hash) -Encoding UTF8
        }
    }
}

function Set-DeliveryOptimizationDhcpDiscovery {
    $key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
    if (-not (Test-Path $key)) {
        New-Item -Path $key -Force | Out-Null
    }
    # 2 = DHCP option 235 Force. Off-site, option is absent and DO uses the CDN.
    New-ItemProperty -Path $key -Name 'DOCacheHostSource' -PropertyType DWord -Value 2 -Force | Out-Null
    if (Get-ItemProperty -Path $key -Name 'DOCacheHost' -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $key -Name 'DOCacheHost' -Force
    }
}

function Remove-DeliveryOptimizationDhcpDiscovery {
    $key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
    if (Test-Path $key) {
        Remove-ItemProperty -Path $key -Name 'DOCacheHostSource' -ErrorAction SilentlyContinue
    }
}

function Invoke-FacilityCacheApply {
    $cfg = Get-FacilityCacheConfig
    $pypiOn = Test-FacilityCache -Port $cfg.PypiPort
    $npmOn = Test-FacilityCache -Port $cfg.NpmPort
    $index = "http://$($cfg.CacheHost):$($cfg.PypiPort)/root/pypi/+simple/"
    $npm = "http://$($cfg.CacheHost):$($cfg.NpmPort)/"
    $pipIni = Join-Path $env:ProgramData 'pip\pip.ini'
    $uvToml = Join-Path $env:ProgramData 'uv\uv.toml'

    if ($pypiOn) {
        Write-ManagedFile -Path $pipIni -Content @"
# facility-cache-managed
[global]
index-url = $index
trusted-host = $($cfg.CacheHost)
"@
        Write-ManagedFile -Path $uvToml -Content @"
# facility-cache-managed
index-url = "$index"
allow-insecure-host = ["$($cfg.CacheHost)"]
"@
        Set-MachineEnv -Name 'PIP_INDEX_URL' -Value $index
        Set-MachineEnv -Name 'PIP_TRUSTED_HOST' -Value $cfg.CacheHost
        Set-MachineEnv -Name 'UV_INDEX_URL' -Value $index
        Set-MachineEnv -Name 'UV_INSECURE_HOST' -Value $cfg.CacheHost
    } else {
        Remove-ManagedFile -Path $pipIni
        Remove-ManagedFile -Path $uvToml
        Set-MachineEnv -Name 'PIP_INDEX_URL' -Value $null
        Set-MachineEnv -Name 'PIP_TRUSTED_HOST' -Value $null
        Set-MachineEnv -Name 'UV_INDEX_URL' -Value $null
        Set-MachineEnv -Name 'UV_INSECURE_HOST' -Value $null
    }

    $npmCmd = Get-Command npm -ErrorAction SilentlyContinue
    if ($npmOn) {
        Set-MachineEnv -Name 'NPM_CONFIG_REGISTRY' -Value $npm
        if ($npmCmd) {
            & npm config set registry $npm --location=global 2>$null
        }
    } else {
        Set-MachineEnv -Name 'NPM_CONFIG_REGISTRY' -Value $null
        if ($npmCmd) {
            # Only clear the global registry if it's still pointed at ours — never
            # blow away a registry someone else configured.
            $currentRegistry = (& npm config get registry --location=global 2>$null)
            if ($currentRegistry -and $currentRegistry.Trim() -eq $npm) {
                & npm config delete registry --location=global 2>$null
            }
        }
    }
}

function ConvertTo-FacilityCacheVersion {
    param([string]$Version)
    $Version = $Version.Trim().TrimStart('v')
    $parts = @()
    foreach ($bit in $Version.Split('.')) {
        $num = 0
        if ($bit -match '^(\d+)') { $num = [int]$Matches[1] }
        $parts += $num
    }
    while ($parts.Count -lt 3) { $parts += 0 }
    return @{ Major = $parts[0]; Minor = $parts[1]; Patch = $parts[2] }
}

function Test-FacilityCacheVersionNewer {
    param([string]$Remote, [string]$Local)
    $a = ConvertTo-FacilityCacheVersion $Remote
    $b = ConvertTo-FacilityCacheVersion $Local
    if ($a.Major -ne $b.Major) { return ($a.Major -gt $b.Major) }
    if ($a.Minor -ne $b.Minor) { return ($a.Minor -gt $b.Minor) }
    return ($a.Patch -gt $b.Patch)
}

function Update-GitHubCliPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $machine) { $machine = '' }
    if (-not $user) { $user = '' }
    $env:Path = "$machine;$user;$env:Path"
    $pf = Join-Path $env:ProgramFiles 'GitHub CLI'
    $exe = Join-Path $pf 'gh.exe'
    if (Test-Path -LiteralPath $exe) {
        $env:Path = "$pf;$env:Path"
    }
}

function Sync-FacilityCacheGitHubCli {
    # Install gh if missing; winget-upgrade (or GitHub Releases MSI) if present.
    # Returns $true when gh is on PATH afterwards. Never throws.
    Update-GitHubCliPath
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if ($winget) {
        $wgArgs = @('--accept-package-agreements', '--accept-source-agreements')
        try {
            if ($gh) {
                & $winget.Path upgrade --id GitHub.cli @wgArgs 2>$null | Out-Null
            } else {
                & $winget.Path install --id GitHub.cli -e --source winget @wgArgs 2>$null | Out-Null
            }
        } catch { }
        Update-GitHubCliPath
        if (Get-Command gh -ErrorAction SilentlyContinue) { return $true }
    }
    try {
        $headers = @{
            'User-Agent' = 'facility-cache-client'
            Accept       = 'application/vnd.github+json'
        }
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/cli/cli/releases/latest' -Headers $headers
        $asset = $release.assets | Where-Object { $_.name -like '*windows_amd64.msi' } | Select-Object -First 1
        if (-not $asset) { return [bool](Get-Command gh -ErrorAction SilentlyContinue) }
        $msi = Join-Path $env:TEMP 'facility-cache-gh.msi'
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $msi -UseBasicParsing
        $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', $msi, '/qn', '/norestart') -Wait -PassThru
        Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
        Update-GitHubCliPath
        if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
            return [bool](Get-Command gh -ErrorAction SilentlyContinue)
        }
    } catch {
        return [bool](Get-Command gh -ErrorAction SilentlyContinue)
    }
    return [bool](Get-Command gh -ErrorAction SilentlyContinue)
}

function Write-FacilityCacheState {
    param($Data)
    $dir = Get-FacilityCacheInstallDir
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Data | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $dir 'state.json') -Encoding UTF8
}

function Update-FacilityCacheClient {
    param(
        [switch]$Check,
        [switch]$Force
    )
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $cfg = Get-FacilityCacheConfig
    $local = Get-FacilityCacheInstalledVersion
    $repo = $cfg.GitHubRepo
    $script:FcStepN = 6
    Write-FcHeader 'facility-cache-client' "update  v$local"
    Write-FcKv 'repo' $repo 'work'
    Write-FcKv 'installed' $local 'ok'
    $headers = @{
        'User-Agent' = "facility-cache-client/$local"
        Accept       = 'application/vnd.github+json'
    }
    if ($cfg.GitHubToken) { $headers['Authorization'] = "Bearer $($cfg.GitHubToken)" }

    if ($cfg.GitHubRepoId) {
        # A rename leaves the old name redirecting, so a re-registered name
        # could serve someone else's releases; the numeric id is immutable.
        Write-FcStep 'identity' "repo id $($cfg.GitHubRepoId)"
        try {
            $meta = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo" -Headers $headers
        } catch {
            Write-FacilityCacheState @{ installed_version = $local; last_result = "github error: $($_.Exception.Message)" }
            Write-FcFail $_
            if ($Check) { throw }
            Write-FcFinish -Ok $false -Message 'could not check GitHub'
            return
        }
        if ([string]$meta.id -ne [string]$cfg.GitHubRepoId) {
            Write-FacilityCacheState @{ installed_version = $local; last_result = "refused: repo id $($meta.id) != pinned $($cfg.GitHubRepoId)" }
            Write-FcFail "Repo id $($meta.id) does not match pinned $($cfg.GitHubRepoId) — the name may have been re-registered; refusing to install from it"
            if ($Check) { throw "repo id mismatch" }
            Write-FcFinish -Ok $false -Message 'refusing to update'
            return
        }
        if ($meta.full_name -ne $repo) {
            Write-FcStepOk "id $($meta.id)  (now named $($meta.full_name))"
            Write-FcNote "repo renamed to $($meta.full_name) — update GitHubRepo in config.json"
        } else {
            Write-FcStepOk "id $($meta.id)"
        }
    }

    Write-FcStep 'github' 'latest release'
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers $headers
    } catch {
        Write-FacilityCacheState @{ installed_version = $local; last_result = "github error: $($_.Exception.Message)" }
        Write-FcFail $_
        if ($Check) { throw }
        Write-FcFinish -Ok $false -Message 'could not check GitHub'
        return
    }

    $assets = @{}
    foreach ($a in $release.assets) { $assets[$a.name] = $a }
    if (-not $assets.ContainsKey('manifest.json')) {
        Write-FacilityCacheState @{ installed_version = $local; last_result = 'no manifest.json'; latest_tag = $release.tag_name }
        Write-FcFail 'Release has no manifest.json'
        Write-FcFinish -Ok $false -Message 'release incomplete'
        return
    }

    $dlHeaders = @{
        'User-Agent' = "facility-cache-client/$local"
        Accept       = 'application/octet-stream'
    }
    if ($cfg.GitHubToken) { $dlHeaders['Authorization'] = "Bearer $($cfg.GitHubToken)" }

    $tmpMan = Join-Path $env:TEMP 'facility-cache-manifest.json'
    Invoke-WebRequest -Uri $assets['manifest.json'].url -Headers $dlHeaders -OutFile $tmpMan -UseBasicParsing
    $manifest = Get-Content -LiteralPath $tmpMan -Raw | ConvertFrom-Json
    $remote = ([string]$manifest.version).TrimStart('v')
    Write-FcStepOk "$($release.tag_name)  v$remote"
    Write-FcKv 'latest' "v$remote" $(if (Test-FacilityCacheVersionNewer $remote $local) { 'ok' } else { 'on' })
    if ($Check) {
        if (Test-FacilityCacheVersionNewer $remote $local) {
            Write-FcOk "update available  v$local -> v$remote"
        } else {
            Write-FcOk 'already the latest release'
        }
        Write-FcFinish -Ok $true -Message "log $(Get-FacilityCacheLogPath)"
        return
    }

    $auto = $true
    if ($null -ne $cfg.AutoUpdate) {
        $auto = [bool]$cfg.AutoUpdate
        if ($cfg.AutoUpdate -is [string]) {
            $auto = @('0', 'false', 'no', 'off') -notcontains $cfg.AutoUpdate.ToLowerInvariant()
        }
    }
    if (-not $auto -and -not $Force) {
        Write-FacilityCacheState @{
            installed_version = $local
            latest_version    = $remote
            last_result       = 'auto-update disabled'
        }
        Write-FcWarn 'AutoUpdate is disabled — pass -Force to install'
        Write-FcFinish -Ok $true -Message 'no changes'
        return
    }
    if (-not $Force -and -not (Test-FacilityCacheVersionNewer -Remote $remote -Local $local)) {
        Write-FacilityCacheState @{
            installed_version = $local
            latest_version    = $remote
            last_result       = 'up-to-date'
        }
        Write-FcOk 'already up to date'
        Write-FcStep 'gh' 'GitHub CLI'
        if (Sync-FacilityCacheGitHubCli) {
            Write-FcStepOk 'gh'
        } else {
            Write-FcWarn 'gh install skipped — attestations may be unavailable'
        }
        Write-FcFinish -Ok $true -Message "v$local"
        return
    }

    $name = $manifest.assets.windows.name
    $expect = ([string]$manifest.assets.windows.sha256).ToLowerInvariant()
    if (-not $name -or -not $expect) { throw 'manifest.json missing windows asset name/sha256' }
    if (-not $assets.ContainsKey($name)) { throw "release is missing asset $name" }

    $tmp = Join-Path $env:TEMP ("facility-cache-" + [guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $zip = Join-Path $tmp $name
        Write-FcStep 'download' $name
        Invoke-WebRequest -Uri $assets[$name].url -Headers $dlHeaders -OutFile $zip -UseBasicParsing
        Write-FcStepOk $name
        Write-FcStep 'verify' 'sha256'
        $got = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($got -ne $expect) { throw "sha256 mismatch: $got != $expect" }
        Write-FcStepOk ($got.Substring(0, 12) + '...')

        Write-FcStep 'gh' 'GitHub CLI'
        if (Sync-FacilityCacheGitHubCli) {
            Write-FcStepOk 'gh'
        } else {
            Write-FcWarn 'gh install skipped — attestations may be unavailable'
        }

        # Best-effort supply-chain nicety on top of the sha256 check above,
        # not a replacement for it: any failure to run/verify `gh` just logs
        # a warning and falls back to trusting sha256, so a fleet without gh
        # (or before attestations existed) never bricks. A hard-fail flag can
        # come later.
        Write-FcStep 'attest' 'build provenance'
        $attested = $false
        $ghCmd = Get-Command gh -ErrorAction SilentlyContinue
        if ($ghCmd) {
            try {
                # Process.Start + WaitForExit(timeout), not `&`, so a wedged gh
                # can't hang this scheduled task forever, and GH_TOKEN is set
                # only for this child process rather than the whole session.
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $ghCmd.Path
                $psi.Arguments = "attestation verify `"$zip`" --repo $repo --signer-workflow $repo/.github/workflows/release.yml --deny-self-hosted-runners"
                $psi.UseShellExecute = $false
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                if ($cfg.GitHubToken) { $psi.EnvironmentVariables['GH_TOKEN'] = $cfg.GitHubToken }
                $proc = [System.Diagnostics.Process]::Start($psi)
                if ($proc.WaitForExit(30000)) {
                    $attested = ($proc.ExitCode -eq 0)
                } else {
                    $proc.Kill()
                }
            } catch {
                $attested = $false
            }
        }
        if ($attested) {
            Write-FcStepOk 'verified'
        } else {
            Write-FcWarn 'attestation unavailable — continuing on sha256 only'
        }

        Write-FcStep 'install' "v$remote"
        Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
        $installer = Get-ChildItem -Path $tmp -Recurse -Filter 'Install-FacilityCache.ps1' | Select-Object -First 1
        if (-not $installer) { throw 'zip missing windows/Install-FacilityCache.ps1' }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer.FullName -NoRestartDocker
        Write-FcStepOk "v$remote"
        Write-FacilityCacheState @{
            installed_version = $remote
            latest_version    = $remote
            last_result       = 'updated'
            from_tag          = $release.tag_name
        }
        Write-FcFinish -Ok $true -Message "now running v$remote"
    } catch {
        Write-FcFail $_
        Write-FcFinish -Ok $false -Message 'update failed'
        throw
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function @(
    'Get-FacilityCacheConfig',
    'Get-FacilityCacheInstalledVersion',
    'Get-FacilityCacheLogPath',
    'Test-FacilityCache',
    'Get-FacilityCacheStatus',
    'Show-FacilityCacheDashboard',
    'Show-FacilityCacheLog',
    'Merge-DockerDaemonJson',
    'Remove-DockerMirrors',
    'Set-DeliveryOptimizationDhcpDiscovery',
    'Remove-DeliveryOptimizationDhcpDiscovery',
    'Invoke-FacilityCacheApply',
    'Update-FacilityCacheClient',
    'Sync-FacilityCacheGitHubCli',
    'Write-FcHeader', 'Write-FcKv', 'Write-FcOk', 'Write-FcFail', 'Write-FcWarn',
    'Write-FcNote', 'Write-FcStep', 'Write-FcStepOk', 'Write-FcBar', 'Write-FcFinish'
)
