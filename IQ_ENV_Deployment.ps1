<#
.SYNOPSIS
    IQ_ENV_Deployment - Pull-based file deployment between DEV / QA / PROD environments.

.DESCRIPTION
    Runs continuously on each of the 11 servers under the technical account 'callssp'.
    Every cycle (default 5 minutes) the local server PULLS files that are destined
    for it from the relevant source servers:

        - QA   servers pull from DEV servers            (trigger folder: 2QA)
        - QA   servers cross-copy from the other QA     (trigger folder: 2QA)
        - PROD servers pull from QA servers             (trigger folders: 2PROD, 2PRODC1, 2PRODC2)
        - PROD servers cross-copy from other PROD       (trigger folders: 2PROD, 2PRODC1, 2PRODC2)

    Trigger folders and their target sets:
        2QA      -> all QA servers
        2PROD    -> all 7 PROD servers
        2PRODC1  -> PROD cluster 1 members (from [CLUSTERS] C1)
        2PRODC2  -> PROD cluster 2 members (from [CLUSTERS] C2)

    The destination path is built by removing the trigger folder from the path:
        E:\Data\se-iciq\Se-Deploy\2QA\Se-common\bat\ABTest.bat
            -> E:\Data\se-iciq\Se-common\bat\ABTest.bat   (on each QA server)

    Completion tracking: after a successful copy, the pulling server registers
    itself in a '.done' file stored on the SOURCE server under 'Se-Deploy\.done\'.
    When all expected target servers are registered and no error is flagged,
    the original source file is deleted (the '.done' file is kept as an audit trail).

    Error handling: if the destination directory does not exist on the pulling
    server, the directory is NOT created. The source file is renamed to
    '<filename>.ERROR_MISSING_DIR' and skipped in subsequent runs until it is
    manually corrected.

.PARAMETER RootPath
    Local root of the deployment share. Default: E:\Data\se-iciq\Se-Deploy

.PARAMETER IniFile
    Path of the servers.ini file. Default: <RootPath>\servers.ini

.PARAMETER ServerName
    Short name override of the local server (e.g. 'Q1'). If omitted, the script
    resolves it from $env:COMPUTERNAME against the servers.ini entries.

.PARAMETER RemoteRootTemplate
    Template used to reach the Se-Deploy root of a remote server.
    '{fqdn}' is replaced by the value found in servers.ini.
    Default: \\{fqdn}\E$\Data\se-iciq\Se-Deploy

.PARAMETER ServerPathMap
    OPTIONAL hashtable (short name -> local root path) that overrides
    RemoteRootTemplate. Used for testing on a single machine.

.PARAMETER IntervalMinutes
    Polling interval. Default 5.

.PARAMETER RunOnce
    Execute a single scan cycle then exit (used for testing / scheduled tasks).

.NOTES
    Author  : IQ_ENV_Deployment
    Account : callssp (technical account, needs read/write on all Se-Deploy shares)
#>

[CmdletBinding()]
param(
    [string]    $RootPath           = 'E:\Data\se-iciq\Se-Deploy',
    [string]    $IniFile            = '',
    [string]    $ServerName         = '',
    [string]    $RemoteRootTemplate = '\\{fqdn}\E$\Data\se-iciq\Se-Deploy',
    [hashtable] $ServerPathMap      = $null,
    [int]       $IntervalMinutes    = 5,
    [switch]    $RunOnce
)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$Script:LogRetentionDays  = 7
$Script:ExcludedExtensions = @('.done', '.lock', '.log')
$Script:ErrorSuffix        = 'ERROR_MISSING_DIR'

# Trigger folder -> logical target group
$Script:TriggerFolders = @('2QA', '2PROD', '2PRODC1', '2PRODC2')

if ([string]::IsNullOrWhiteSpace($IniFile)) {
    $IniFile = Join-Path $RootPath 'servers.ini'
}
$Script:LogDir  = Join-Path $RootPath 'Logs'
$Script:DoneDirName = '.done'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-DeployLog {
    param(
        [string] $Action,
        [string] $SourceFile   = '',
        [string] $Destinations = '',
        [ValidateSet('SUCCESS','FAIL','INFO')] [string] $Status = 'INFO',
        [string] $ErrorMessage = ''
    )
    try {
        if (-not (Test-Path $Script:LogDir)) {
            New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
        }
        $logFile = Join-Path $Script:LogDir ("IQ_ENV_Deployment_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
        $line = "{0}|{1}|{2}|{3}|{4}|{5}|{6}" -f
            (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
            $Script:LocalServer,
            $Action,
            $SourceFile,
            $Destinations,
            $Status,
            $ErrorMessage
        Add-Content -Path $logFile -Value $line -Encoding UTF8
        Write-Verbose $line
    }
    catch {
        Write-Warning "Unable to write log entry: $_"
    }
}

function Remove-OldLogs {
    # Keep only the last 7 daily log files.
    try {
        if (-not (Test-Path $Script:LogDir)) { return }
        $limit = (Get-Date).Date.AddDays(-($Script:LogRetentionDays - 1))
        Get-ChildItem -Path $Script:LogDir -Filter 'IQ_ENV_Deployment_*.log' -File |
            Where-Object {
                $_.BaseName -match 'IQ_ENV_Deployment_(\d{8})$' -and
                ([datetime]::ParseExact($Matches[1], 'yyyyMMdd', $null) -lt $limit)
            } |
            ForEach-Object {
                Remove-Item $_.FullName -Force
                Write-DeployLog -Action 'LOG_CLEANUP' -SourceFile $_.Name -Status 'SUCCESS'
            }
    }
    catch {
        Write-DeployLog -Action 'LOG_CLEANUP' -Status 'FAIL' -ErrorMessage $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
# INI parsing
# ---------------------------------------------------------------------------
function Read-IniFile {
    param([string] $Path)
    if (-not (Test-Path $Path)) {
        throw "servers.ini not found at '$Path'."
    }
    $ini = [ordered]@{}
    $section = ''
    foreach ($rawLine in Get-Content -Path $Path) {
        $line = $rawLine.Trim()
        if ($line -eq '' -or $line.StartsWith(';') -or $line.StartsWith('#')) { continue }
        if ($line -match '^\[(.+)\]$') {
            $section = $Matches[1].Trim().ToUpper()
            if (-not $ini.Contains($section)) { $ini[$section] = [ordered]@{} }
            continue
        }
        if ($section -ne '' -and $line -match '^([^=]+)=(.*)$') {
            $key   = $Matches[1].Trim().ToUpper()
            $value = $Matches[2].Trim()
            $ini[$section][$key] = $value
        }
    }
    return $ini
}

function Initialize-Topology {
    # Builds the environment model from servers.ini into script-scoped variables.
    $ini = Read-IniFile -Path $IniFile

    foreach ($required in @('DEV','QA','PROD','CLUSTERS')) {
        if (-not $ini.Contains($required)) {
            throw "servers.ini is missing the [$required] section."
        }
    }

    $Script:Servers = @{}   # short name -> @{ Fqdn; Env }
    foreach ($env in @('DEV','QA','PROD')) {
        foreach ($key in $ini[$env].Keys) {
            $Script:Servers[$key] = @{ Fqdn = $ini[$env][$key]; Env = $env }
        }
    }

    $Script:DevServers  = @($ini['DEV'].Keys)
    $Script:QaServers   = @($ini['QA'].Keys)
    $Script:ProdServers = @($ini['PROD'].Keys)

    # Clusters: values are comma (or semicolon) separated short names.
    $Script:Clusters = @{}
    foreach ($key in $ini['CLUSTERS'].Keys) {
        $members = $ini['CLUSTERS'][$key] -split '[,;]' | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ }
        $Script:Clusters[$key] = @($members)
    }
    if (-not $Script:Clusters.ContainsKey('C1')) { throw "servers.ini [CLUSTERS] must define C1." }
    if (-not $Script:Clusters.ContainsKey('C2')) { throw "servers.ini [CLUSTERS] must define C2." }
}

function Resolve-LocalServer {
    # Returns the short name (D1/Q1/P1/...) of the machine the script runs on.
    if ($ServerName) {
        $short = $ServerName.ToUpper()
        if (-not $Script:Servers.ContainsKey($short)) {
            throw "ServerName '$ServerName' is not defined in servers.ini."
        }
        return $short
    }
    $hostName = $env:COMPUTERNAME
    if (-not $hostName) { $hostName = [System.Net.Dns]::GetHostName() }
    foreach ($short in $Script:Servers.Keys) {
        $fqdn = $Script:Servers[$short].Fqdn
        $firstLabel = ($fqdn -split '\.')[0].TrimStart('\', 'I')
        if ($fqdn -ieq $hostName -or $firstLabel -ieq $hostName) { return $short }
    }
    throw "Local host '$hostName' could not be matched against servers.ini. Use -ServerName to force it."
}

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------
function Get-ServerRoot {
    # Returns the Se-Deploy root path of a given server (local path or UNC).
    param([string] $Short)
    if ($Short -ieq $Script:LocalServer) { return $RootPath }
    if ($ServerPathMap -and $ServerPathMap.ContainsKey($Short)) {
        return $ServerPathMap[$Short]
    }
    $fqdn = $Script:Servers[$Short].Fqdn
    return $RemoteRootTemplate.Replace('{fqdn}', $fqdn)
}

function Get-DestinationPath {
    <#
        Removes the trigger folder from the relative path and re-anchors it one
        level above the local Se-Deploy folder.
        Example: relative '2QA\Se-common\bat\ABTest.bat'
                 -> <parent of RootPath>\Se-common\bat\ABTest.bat
    #>
    param([string] $RelativePath)
    $parts = $RelativePath -split '[\\/]' | Where-Object { $_ }
    $rest  = $parts[1..($parts.Count - 1)]          # drop the trigger folder
    $base  = Split-Path -Path $RootPath -Parent     # parent of Se-Deploy
    return (Join-Path $base ($rest -join [IO.Path]::DirectorySeparatorChar))
}

function Get-ExpectedTargets {
    # Target servers of a trigger folder, excluding the source server itself.
    param([string] $Trigger, [string] $SourceServer)
    $targets = switch ($Trigger.ToUpper()) {
        '2QA'     { $Script:QaServers }
        '2PROD'   { $Script:ProdServers }
        '2PRODC1' { $Script:Clusters['C1'] }
        '2PRODC2' { $Script:Clusters['C2'] }
        default   { @() }
    }
    return @($targets | Where-Object { $_ -ine $SourceServer })
}

function Get-PullPlan {
    <#
        Determines, for the local server, which (source server, trigger folder)
        pairs must be scanned. Pull chain:
            QA   <- DEV (2QA)  and cross-copy from other QA (2QA)
            PROD <- QA  (2PROD/2PRODC1/2PRODC2) and cross-copy from other PROD
        DEV servers do not pull (same-environment DEV->DEV transfer is excluded).
    #>
    $plan = @()
    $env  = $Script:Servers[$Script:LocalServer].Env

    if ($env -eq 'QA') {
        foreach ($src in $Script:DevServers) { $plan += ,@($src, '2QA') }
        foreach ($src in ($Script:QaServers | Where-Object { $_ -ine $Script:LocalServer })) {
            $plan += ,@($src, '2QA')
        }
    }
    elseif ($env -eq 'PROD') {
        $myTriggers = @('2PROD')
        if ($Script:Clusters['C1'] -icontains $Script:LocalServer) { $myTriggers += '2PRODC1' }
        if ($Script:Clusters['C2'] -icontains $Script:LocalServer) { $myTriggers += '2PRODC2' }

        foreach ($src in $Script:QaServers) {
            foreach ($t in $myTriggers) { $plan += ,@($src, $t) }
        }
        foreach ($src in ($Script:ProdServers | Where-Object { $_ -ine $Script:LocalServer })) {
            foreach ($t in $myTriggers) { $plan += ,@($src, $t) }
        }
    }
    return $plan
}

# ---------------------------------------------------------------------------
# .done file handling (stored on the SOURCE server, with .lock protection)
# ---------------------------------------------------------------------------
function Get-DoneFilePath {
    param([string] $SourceRoot, [string] $RelativePath)
    $doneDir = Join-Path $SourceRoot $Script:DoneDirName
    $flat = ($RelativePath -replace '[\\/]', '_')
    return (Join-Path $doneDir ("{0}.done" -f $flat))
}

function Invoke-WithLock {
    # Serializes concurrent .done updates from several pulling servers.
    param([string] $DoneFile, [scriptblock] $Action)
    $lockFile = "$DoneFile.lock"
    $acquired = $false
    for ($i = 0; $i -lt 20 -and -not $acquired; $i++) {
        try {
            $fs = [System.IO.File]::Open($lockFile, [System.IO.FileMode]::CreateNew,
                                         [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $fs.Close()
            $acquired = $true
        }
        catch { Start-Sleep -Milliseconds (Get-Random -Minimum 150 -Maximum 500) }
    }
    if (-not $acquired) { throw "Could not acquire lock '$lockFile'." }
    try     { & $Action }
    finally { Remove-Item -Path $lockFile -Force -ErrorAction SilentlyContinue }
}

function Get-DoneServers {
    # Returns the list of servers already registered in a .done file.
    param([string] $DoneFile)
    if (-not (Test-Path $DoneFile)) { return @() }
    $servers = @()
    foreach ($line in (Get-Content $DoneFile)) {
        if ($line -match '^COPIED\|([^|]+)\|') { $servers += $Matches[1].Trim().ToUpper() }
    }
    return $servers
}

function Register-CopyDone {
    <#
        Registers the local server in the .done file of the source.
        If all expected targets are now registered, deletes the original file.
        The .done file is kept as an audit trail.
    #>
    param(
        [string]   $SourceRoot,
        [string]   $SourceFileFull,
        [string]   $RelativePath,
        [string[]] $ExpectedTargets
    )
    $doneDir = Join-Path $SourceRoot $Script:DoneDirName
    if (-not (Test-Path $doneDir)) {
        New-Item -ItemType Directory -Path $doneDir -Force | Out-Null
    }
    $doneFile = Get-DoneFilePath -SourceRoot $SourceRoot -RelativePath $RelativePath

    Invoke-WithLock -DoneFile $doneFile -Action {
        if (-not (Test-Path $doneFile)) {
            Add-Content -Path $doneFile -Value ("SOURCE|{0}" -f $RelativePath) -Encoding UTF8
        }
        $already = Get-DoneServers -DoneFile $doneFile
        if ($already -notcontains $Script:LocalServer) {
            Add-Content -Path $doneFile -Encoding UTF8 -Value (
                "COPIED|{0}|{1}" -f $Script:LocalServer, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        }
        $registered = Get-DoneServers -DoneFile $doneFile
        $missing = @($ExpectedTargets | Where-Object { $registered -notcontains $_.ToUpper() })

        if ($missing.Count -eq 0 -and (Test-Path $SourceFileFull)) {
            # All targets served and no error flagged -> delete the original file.
            Remove-Item -Path $SourceFileFull -Force
            Add-Content -Path $doneFile -Encoding UTF8 -Value (
                "COMPLETED|ALL_TARGETS|{0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
            Write-DeployLog -Action 'DELETE_SOURCE' -SourceFile $RelativePath `
                -Destinations ($ExpectedTargets -join ',') -Status 'SUCCESS'
        }
    }
}

# ---------------------------------------------------------------------------
# File selection and copy
# ---------------------------------------------------------------------------
function Get-CandidateFiles {
    # Files eligible for transfer inside <SourceRoot>\<Trigger>\ .
    param([string] $SourceRoot, [string] $Trigger)
    $triggerPath = Join-Path $SourceRoot $Trigger
    if (-not (Test-Path $triggerPath)) { return @() }

    Get-ChildItem -Path $triggerPath -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            ($Script:ExcludedExtensions -notcontains $_.Extension.ToLower()) -and
            ($_.Name -notmatch '\.ERROR_[A-Z_]+$') -and
            (-not ($_.Attributes -band [IO.FileAttributes]::Hidden)) -and
            (-not ($_.Attributes -band [IO.FileAttributes]::System))
        }
}

function Invoke-PullCycle {
    # One full scan/pull cycle for the local server.
    $plan = Get-PullPlan
    foreach ($entry in $plan) {
        $srcServer = $entry[0]
        $trigger   = $entry[1]
        $srcRoot   = Get-ServerRoot -Short $srcServer

        if (-not (Test-Path $srcRoot)) {
            Write-DeployLog -Action 'SCAN' -SourceFile $srcRoot -Destinations $srcServer `
                -Status 'FAIL' -ErrorMessage "Source root not reachable"
            continue
        }

        foreach ($file in (Get-CandidateFiles -SourceRoot $srcRoot -Trigger $trigger)) {
            # Relative path starting at the trigger folder, e.g. 2QA\Se-common\bat\ABTest.bat
            $rel = $file.FullName.Substring($srcRoot.Length).TrimStart('\','/')
            $expected = Get-ExpectedTargets -Trigger $trigger -SourceServer $srcServer
            if ($expected -notcontains $Script:LocalServer) { continue }  # not for me

            $doneFile = Get-DoneFilePath -SourceRoot $srcRoot -RelativePath $rel
            if ((Get-DoneServers -DoneFile $doneFile) -contains $Script:LocalServer) { continue }  # already pulled

            $destination = Get-DestinationPath -RelativePath $rel
            $destDir     = Split-Path -Path $destination -Parent

            if (-not (Test-Path $destDir)) {
                # Destination folder missing: do NOT create it. Flag the source file.
                $errMsg = "Destination directory missing: $destDir"
                Write-DeployLog -Action 'COPY' -SourceFile $rel -Destinations $Script:LocalServer `
                    -Status 'FAIL' -ErrorMessage $errMsg
                try {
                    Rename-Item -Path $file.FullName -NewName ("{0}.{1}" -f $file.Name, $Script:ErrorSuffix) -ErrorAction Stop
                    Write-DeployLog -Action 'RENAME_ERROR_FILE' -SourceFile $rel `
                        -Destinations $srcServer -Status 'SUCCESS' -ErrorMessage $Script:ErrorSuffix
                }
                catch {
                    Write-DeployLog -Action 'RENAME_ERROR_FILE' -SourceFile $rel `
                        -Destinations $srcServer -Status 'FAIL' -ErrorMessage $_.Exception.Message
                }
                continue
            }

            try {
                Copy-Item -Path $file.FullName -Destination $destination -Force -ErrorAction Stop
                Write-DeployLog -Action 'COPY' -SourceFile $rel -Destinations $Script:LocalServer -Status 'SUCCESS'
                Register-CopyDone -SourceRoot $srcRoot -SourceFileFull $file.FullName `
                    -RelativePath $rel -ExpectedTargets $expected
            }
            catch {
                Write-DeployLog -Action 'COPY' -SourceFile $rel -Destinations $Script:LocalServer `
                    -Status 'FAIL' -ErrorMessage $_.Exception.Message
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try {
    Initialize-Topology
    $Script:LocalServer = Resolve-LocalServer
}
catch {
    Write-Error $_
    exit 1
}

Write-DeployLog -Action 'STARTUP' -Status 'INFO' `
    -ErrorMessage ("Role={0}; Interval={1}min" -f $Script:Servers[$Script:LocalServer].Env, $IntervalMinutes)

do {
    try {
        Remove-OldLogs
        Invoke-PullCycle
    }
    catch {
        Write-DeployLog -Action 'CYCLE' -Status 'FAIL' -ErrorMessage $_.Exception.Message
    }
    if (-not $RunOnce) { Start-Sleep -Seconds ($IntervalMinutes * 60) }
} while (-not $RunOnce)

Write-DeployLog -Action 'SHUTDOWN' -Status 'INFO'
