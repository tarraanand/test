<#
.SYNOPSIS
    Synchronizes metadata files between DEV -> QA and QA -> PROD using timestamp comparison.

.DESCRIPTION
    Pull-based file synchronization driven entirely by an INI configuration file.

    The script determines which server it is running on (by hostname lookup in the INI),
    derives its environment (DEV / QA / PROD), resolves the source environment from the
    [MAPPING] section, and then pulls changed files from every server of the source
    environment into a per-source-server folder underneath DestinationBasePath.

        Running on Q1 (QA)   -> pulls from D1, D2   -> E:\Data\se-iciq\se-deploy\D1, ...\D2
        Running on P1 (PROD) -> pulls from Q1, Q2   -> E:\Data\se-iciq\se-deploy\Q1, ...\Q2

    Transfers inside the same environment never happen: the mapping table only ever points
    an environment at a different environment.

    Key behaviours
      - Change detection by LastWriteTime (UTC) with a configurable tolerance, optionally
        combined with a file size comparison. No hashing.
      - [INCLUDE] / [EXCLUDE] paths are relative to the source root and support wildcards.
      - Files larger than MaxFileSizeMB are skipped with a WARNING, unless the file is
        listed explicitly (as a file, not a folder) in [INCLUDE], in which case it is
        copied and a WARNING is logged.
      - Copies run in parallel through a throttled runspace pool.
      - Retries on transient/network errors, no retry on access-denied or disk-full.
      - One log file per day, automatic purge after LogRetentionDays.
      - Lock file prevents overlapping executions.
      - -WhatIf simulates everything without writing a single destination file.

.PARAMETER ConfigPath
    Path to servers.ini. Default: E:\Data\se-iciq\se-deploy\servers.ini

.PARAMETER RunOnce
    Execute a single synchronization cycle and exit. Use this when the script is driven by
    a Scheduled Task. Without it, the script loops forever, sleeping SyncIntervalMinutes
    between cycles (the "runs continuously" model).

.PARAMETER LocalServerCode
    Overrides hostname auto-detection. Mainly for testing and for hosts whose Windows
    computer name does not match the INI entry.

.PARAMETER MaxCycles
    Safety valve for continuous mode / testing: stop after N cycles. 0 = unlimited.

.PARAMETER WhatIf
    Simulates actions without copying files. Every action is logged with status WHATIF.

.EXAMPLE
    .\Sync-SeDeploy.ps1 -RunOnce -WhatIf
    Dry run of one cycle on the local server.

.EXAMPLE
    .\Sync-SeDeploy.ps1 -ConfigPath 'E:\Data\se-iciq\se-deploy\servers.ini' -RunOnce
    One real cycle, the form used by the Scheduled Task.

.NOTES
    Account       : callssp (requires READ on the source shares, READ+WRITE on the local
                    destination tree - read on the destination is mandatory because the
                    timestamp comparison has to stat the existing files).
    Compatibility : Windows PowerShell 5.1 and PowerShell 7.x.
    Version       : 1.0.0
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath = 'E:\Data\se-iciq\se-deploy\servers.ini',
    [switch]$RunOnce,
    [string]$LocalServerCode,
    [int]$MaxCycles = 0,
    # Loads the functions without executing anything. Used by Test-SyncSeDeploy.ps1.
    [switch]$LoadFunctionsOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Script:Sep = [System.IO.Path]::DirectorySeparatorChar
$Script:LogFilePath = $null
$Script:LogDate = $null
$Script:LocalCode = $null
$Script:Stats = $null
$Script:ScriptVersion = '1.0.0'

# ---------------------------------------------------------------------------
# region INI parsing
# ---------------------------------------------------------------------------

function Read-IniFile {
    <#
        Tolerant INI reader. Accepts [SECTION], (SECTION], [SECTION) - the requirement
        document contained both typos, and a malformed bracket should not silently drop a
        whole section. Sections hold either key=value pairs or bare list entries
        (used by [INCLUDE] / [EXCLUDE]).
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Configuration file not found: $Path"
    }

    $result = [ordered]@{}
    $current = $null
    $lineNo = 0

    foreach ($rawLine in (Get-Content -LiteralPath $Path)) {
        $lineNo++
        $line = $rawLine.Trim()

        if ($line.Length -eq 0) { continue }
        if ($line.StartsWith('#') -or $line.StartsWith(';')) { continue }

        if ($line -match '^[\[\(]\s*([^\]\)]+?)\s*[\]\)]$') {
            $current = $matches[1].ToUpperInvariant()
            if (-not $result.Contains($current)) {
                $result[$current] = [ordered]@{ Keys = [ordered]@{}; Items = New-Object System.Collections.ArrayList }
            }
            continue
        }

        if ($null -eq $current) {
            Write-Verbose "servers.ini line $lineNo ignored (outside of any section): $line"
            continue
        }

        $eq = $line.IndexOf('=')
        if ($eq -gt 0) {
            $key = $line.Substring(0, $eq).Trim()
            $value = $line.Substring($eq + 1).Trim()
            $result[$current].Keys[$key] = $value
            [void]$result[$current].Items.Add($value)
        }
        else {
            [void]$result[$current].Items.Add($line)
        }
    }

    return $result
}

function Get-IniValue {
    param(
        [Parameter(Mandatory = $true)]$Ini,
        [Parameter(Mandatory = $true)][string]$Section,
        [Parameter(Mandatory = $true)][string]$Key,
        $Default = $null
    )
    $sec = $Section.ToUpperInvariant()
    if ($Ini.Contains($sec) -and $Ini[$sec].Keys.Contains($Key)) {
        $v = $Ini[$sec].Keys[$Key]
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
    }
    return $Default
}

function Get-IniInt {
    param($Ini, [string]$Section, [string]$Key, [int]$Default)
    $raw = Get-IniValue -Ini $Ini -Section $Section -Key $Key -Default $null
    if ($null -eq $raw) { return $Default }
    $parsed = 0
    if ([int]::TryParse(([string]$raw).Trim(), [ref]$parsed)) { return $parsed }
    Write-Warning "servers.ini: [$Section] $Key = '$raw' is not a number, using default $Default"
    return $Default
}

function Get-IniBool {
    param($Ini, [string]$Section, [string]$Key, [bool]$Default)
    $raw = Get-IniValue -Ini $Ini -Section $Section -Key $Key -Default $null
    if ($null -eq $raw) { return $Default }
    switch (([string]$raw).Trim().ToLowerInvariant()) {
        'true'  { return $true }
        '1'     { return $true }
        'yes'   { return $true }
        'y'     { return $true }
        'false' { return $false }
        '0'     { return $false }
        'no'    { return $false }
        'n'     { return $false }
        default {
            Write-Warning "servers.ini: [$Section] $Key = '$raw' is not a boolean, using default $Default"
            return $Default
        }
    }
}

# ---------------------------------------------------------------------------
# region Path helpers
# ---------------------------------------------------------------------------

function ConvertTo-NativePath {
    <# Normalizes separators so the same INI works on Windows (\) and during tests. #>
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    if ($Script:Sep -eq '\') { return ($Path -replace '/', '\') }
    return ($Path -replace '\\', '/')
}

function Join-NativePath {
    <# Joins a base path with a relative path expressed with either separator. #>
    param([string]$Base, [string]$Relative)
    $out = $Base.TrimEnd('\', '/')
    if ([string]::IsNullOrWhiteSpace($Relative)) { return $out }
    foreach ($part in ($Relative -split '[\\/]+')) {
        if ($part.Length -eq 0) { continue }
        $out = $out + $Script:Sep + $part
    }
    return $out
}

function Get-RelativePath {
    <# Returns the path below $Root, always expressed with backslashes (log/INI style). #>
    param([string]$FullPath, [string]$Root)
    $rootNorm = $Root.TrimEnd('\', '/')
    if ($FullPath.Length -le $rootNorm.Length) { return '' }
    $rel = $FullPath.Substring($rootNorm.Length).TrimStart('\', '/')
    return ($rel -replace '/', '\')
}

# ---------------------------------------------------------------------------
# region Logging
# ---------------------------------------------------------------------------

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1MB) { return ('{0:N1}MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1}KB' -f ($Bytes / 1KB)) }
    return ('{0}B' -f $Bytes)
}

function Initialize-LogFile {
    param([Parameter(Mandatory = $true)]$Config)

    $today = (Get-Date).ToString('yyyy-MM-dd')
    if ($Script:LogDate -eq $today -and $null -ne $Script:LogFilePath) { return }

    if (-not (Test-Path -LiteralPath $Config.LogPath)) {
        New-Item -ItemType Directory -Path $Config.LogPath -Force | Out-Null
    }
    $Script:LogDate = $today
    $Script:LogFilePath = Join-NativePath -Base $Config.LogPath -Relative ("se-deploy-sync_{0}.log" -f $today)
}

function Write-LogLine {
    <# Single writer: only the main thread ever touches the log file. #>
    param([Parameter(Mandatory = $true)][string]$Line)

    Write-Verbose $Line
    if ($null -eq $Script:LogFilePath) { return }

    $attempt = 0
    while ($true) {
        try {
            Add-Content -LiteralPath $Script:LogFilePath -Value $Line -Encoding UTF8 -ErrorAction Stop
            return
        }
        catch {
            $attempt++
            if ($attempt -ge 3) {
                Write-Warning "Unable to write to log file '$($Script:LogFilePath)': $($_.Exception.Message)"
                return
            }
            Start-Sleep -Milliseconds 200
        }
    }
}

function Write-SyncLog {
    <#
        Structured record:
        [TIMESTAMP] | [SERVER] | [ACTION] | [SOURCE_FILE] | [DESTINATION_SERVERS] | [STATUS] | [SIZE] | [DURATION] | [ERROR]
        In a pull model SERVER is the source server the file came from and
        DESTINATION_SERVERS is the local server doing the pull.
    #>
    param(
        [string]$Server = 'SYSTEM',
        [Parameter(Mandatory = $true)][string]$Action,
        [string]$SourceFile = '-',
        [string]$DestinationServers = '-',
        [string]$Status = '-',
        [string]$Size = '-',
        [string]$Duration = '-',
        [string]$ErrorText = '-'
    )

    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $err = $ErrorText
    if ([string]::IsNullOrWhiteSpace($err)) { $err = '-' }
    $err = ($err -replace '[\r\n]+', ' ').Trim()

    Write-LogLine ('{0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8}' -f `
            $ts, $Server, $Action, $SourceFile, $DestinationServers, $Status, $Size, $Duration, $err)
}

function Write-HeartbeatLog {
    param([datetime]$NextRun)
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-LogLine ('{0} | SYSTEM | HEARTBEAT | Script active | Next run: {1}' -f $ts, $NextRun.ToString('HH:mm:ss'))
}

function Write-SummaryLog {
    param([Parameter(Mandatory = $true)]$Stats, [string]$Timestamp)
    if ([string]::IsNullOrWhiteSpace($Timestamp)) {
        $Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $avg = 0
    if ($Stats.Copied -gt 0) { $avg = [math]::Round($Stats.TotalDurationMs / $Stats.Copied) }
    Write-LogLine ('{0} | SYSTEM | SUMMARY | Files copied: {1} | Errors: {2} | Warnings: {3} | Avg duration: {4}ms' -f `
            $Timestamp, $Stats.Copied, $Stats.Errors, $Stats.Warnings, $avg)
}

function New-StatsObject {
    param([string]$Date)
    return [pscustomobject]@{
        Date            = $Date
        Copied          = 0
        Errors          = 0
        Warnings        = 0
        Skipped         = 0
        TotalDurationMs = 0
    }
}

function Update-DailyStats {
    <# Emits the daily summary when the date rolls over, then starts a fresh counter set. #>
    param([Parameter(Mandatory = $true)]$Config)

    $today = (Get-Date).ToString('yyyy-MM-dd')
    if ($null -eq $Script:Stats) {
        $Script:Stats = New-StatsObject -Date $today
        return
    }
    if ($Script:Stats.Date -ne $today) {
        Write-SummaryLog -Stats $Script:Stats -Timestamp ("{0} 23:59:59" -f $Script:Stats.Date)
        $Script:Stats = New-StatsObject -Date $today
        Initialize-LogFile -Config $Config
        Remove-OldLogFile -Config $Config
    }
}

function Remove-OldLogFile {
    param([Parameter(Mandatory = $true)]$Config)
    try {
        # Keep LogRetentionDays files in total, today's log included.
        $cutoff = (Get-Date).Date.AddDays(-1 * ($Config.LogRetentionDays - 1))
        $old = Get-ChildItem -LiteralPath $Config.LogPath -Filter 'se-deploy-sync_*.log' -File -ErrorAction Stop |
            Where-Object { $_.LastWriteTime -lt $cutoff }
        foreach ($f in $old) {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            Write-SyncLog -Action 'LOG_PURGE' -SourceFile $f.Name -Status 'SUCCESS'
        }
    }
    catch {
        Write-SyncLog -Action 'LOG_PURGE' -Status 'FAIL' -ErrorText $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
# region Configuration
# ---------------------------------------------------------------------------

function Get-SyncConfiguration {
    param([Parameter(Mandatory = $true)][string]$Path)

    $ini = Read-IniFile -Path $Path

    $cfg = [ordered]@{
        ConfigPath                = $Path
        BasePath                  = ConvertTo-NativePath (Get-IniValue $ini 'GLOBAL' 'BasePath' 'E:\Data\se-iciq\')
        DestinationBasePath       = ConvertTo-NativePath (Get-IniValue $ini 'GLOBAL' 'DestinationBasePath' 'E:\Data\se-iciq\se-deploy\')
        LogPath                   = ConvertTo-NativePath (Get-IniValue $ini 'GLOBAL' 'LogPath' 'E:\Data\se-iciq\se-deploy\Logs\')
        LockFilePath              = ConvertTo-NativePath (Get-IniValue $ini 'GLOBAL' 'LockFilePath' '')
        SourceRootTemplate        = Get-IniValue $ini 'GLOBAL' 'SourceRootTemplate' '{SERVER}\E$\Data\se-iciq'
        LogRetentionDays          = Get-IniInt  $ini 'GLOBAL' 'LogRetentionDays' 7
        SyncIntervalMinutes       = Get-IniInt  $ini 'GLOBAL' 'SyncIntervalMinutes' 10
        MaxFileSizeMB             = Get-IniInt  $ini 'GLOBAL' 'MaxFileSizeMB' 100
        MaxConcurrentCopies       = Get-IniInt  $ini 'GLOBAL' 'MaxConcurrentCopies' 4
        RetryCount                = Get-IniInt  $ini 'GLOBAL' 'RetryCount' 3
        RetryDelaySeconds         = Get-IniInt  $ini 'GLOBAL' 'RetryDelaySeconds' 5
        MinFreeSpaceMB            = Get-IniInt  $ini 'GLOBAL' 'MinFreeSpaceMB' 1024
        LockTimeoutMinutes        = Get-IniInt  $ini 'GLOBAL' 'LockTimeoutMinutes' 60
        TimestampToleranceSeconds = Get-IniInt  $ini 'GLOBAL' 'TimestampToleranceSeconds' 2
        DiskFullPauseMinutes      = Get-IniInt  $ini 'GLOBAL' 'DiskFullPauseMinutes' 30
        CompareFileSize           = Get-IniBool $ini 'GLOBAL' 'CompareFileSize' $true
        PreserveTimestamps        = Get-IniBool $ini 'GLOBAL' 'PreserveTimestamps' $true
        MatchExcludeAtAnyDepth    = Get-IniBool $ini 'GLOBAL' 'MatchExcludeAtAnyDepth' $true
        WarnOnMissingIncludePath  = Get-IniBool $ini 'GLOBAL' 'WarnOnMissingIncludePath' $true
        Environments              = [ordered]@{}
        ServerEnvironment         = @{}
        ServerHost                = [ordered]@{}
        SourceRootOverrides       = @{}
        Mapping                   = @{}
        Include                   = New-Object System.Collections.ArrayList
        Exclude                   = New-Object System.Collections.ArrayList
        Clusters                  = [ordered]@{}
    }

    # --- environments and their servers -------------------------------------
    foreach ($envName in @('DEV', 'QA', 'PROD')) {
        $servers = [ordered]@{}
        if ($ini.Contains($envName)) {
            foreach ($k in $ini[$envName].Keys.Keys) {
                $code = $k.Trim().ToUpperInvariant()
                $servers[$code] = $ini[$envName].Keys[$k].Trim()
                $cfg.ServerEnvironment[$code] = $envName
                $cfg.ServerHost[$code] = $ini[$envName].Keys[$k].Trim()
            }
        }
        $cfg.Environments[$envName] = $servers
    }

    # --- environment mapping (destination env -> source env) ----------------
    $defaultMapping = @{ 'QA' = 'DEV'; 'PROD' = 'QA' }
    if ($ini.Contains('MAPPING')) {
        foreach ($k in $ini['MAPPING'].Keys.Keys) {
            $cfg.Mapping[$k.Trim().ToUpperInvariant()] = $ini['MAPPING'].Keys[$k].Trim().ToUpperInvariant()
        }
    }
    foreach ($k in $defaultMapping.Keys) {
        if (-not $cfg.Mapping.ContainsKey($k)) { $cfg.Mapping[$k] = $defaultMapping[$k] }
    }
    # Guard: an environment may never be its own source.
    foreach ($k in @($cfg.Mapping.Keys)) {
        if ($cfg.Mapping[$k] -eq $k) {
            throw "servers.ini [MAPPING]: '$k = $k' would synchronize an environment with itself, which is forbidden."
        }
    }

    # --- optional per-source-environment root overrides ---------------------
    if ($ini.Contains('SOURCEROOT')) {
        foreach ($k in $ini['SOURCEROOT'].Keys.Keys) {
            $cfg.SourceRootOverrides[$k.Trim().ToUpperInvariant()] = $ini['SOURCEROOT'].Keys[$k].Trim()
        }
    }

    # --- include / exclude ---------------------------------------------------
    foreach ($sec in @('INCLUDE', 'EXCLUDE')) {
        if (-not $ini.Contains($sec)) { continue }
        foreach ($item in $ini[$sec].Items) {
            $v = ([string]$item).Trim()
            if ($v.Length -eq 0) { continue }
            if ($sec -eq 'INCLUDE') { [void]$cfg.Include.Add($v) } else { [void]$cfg.Exclude.Add($v) }
        }
    }

    # --- clusters (informational only) --------------------------------------
    if ($ini.Contains('CLUSTERS')) {
        foreach ($k in $ini['CLUSTERS'].Keys.Keys) {
            $cfg.Clusters[$k.Trim()] = ($ini['CLUSTERS'].Keys[$k] -split '[,;]' | ForEach-Object { $_.Trim().ToUpperInvariant() } | Where-Object { $_ })
        }
    }

    if ($cfg.Include.Count -eq 0) {
        throw "servers.ini: [INCLUDE] is empty - nothing would ever be synchronized."
    }
    if ($cfg.MaxConcurrentCopies -lt 1) { $cfg.MaxConcurrentCopies = 1 }
    if ($cfg.RetryCount -lt 1) { $cfg.RetryCount = 1 }
    if ($cfg.SyncIntervalMinutes -lt 1) { $cfg.SyncIntervalMinutes = 1 }

    if ([string]::IsNullOrWhiteSpace($cfg.LockFilePath)) {
        $cfg.LockFilePath = Join-NativePath -Base $cfg.DestinationBasePath -Relative 'se-deploy-sync.lock'
    }

    return [pscustomobject]$cfg
}

function Resolve-LocalServerCode {
    <# Matches the local computer name against the host values in the INI. #>
    param([Parameter(Mandatory = $true)]$Config, [string]$Override)

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        $code = $Override.Trim().ToUpperInvariant()
        if (-not $Config.ServerEnvironment.ContainsKey($code)) {
            throw "Server code '$code' is not defined in any of the [DEV]/[QA]/[PROD] sections of $($Config.ConfigPath)."
        }
        return $code
    }

    $names = New-Object System.Collections.ArrayList
    if ($env:COMPUTERNAME) { [void]$names.Add($env:COMPUTERNAME) }
    try { [void]$names.Add([System.Net.Dns]::GetHostName()) } catch { }
    try { [void]$names.Add([System.Net.Dns]::GetHostEntry('').HostName) } catch { }

    foreach ($code in $Config.ServerHost.Keys) {
        $hostValue = $Config.ServerHost[$code].TrimStart('\', '/')
        $shortHost = ($hostValue -split '\.')[0]
        foreach ($n in $names) {
            if ([string]::IsNullOrWhiteSpace($n)) { continue }
            $shortLocal = ($n -split '\.')[0]
            if ($shortLocal -eq $shortHost -or $n -eq $hostValue) { return $code }
        }
    }

    $msg = "This computer ({0}) does not match any server defined in {1}. " -f ($names -join ', '), $Config.ConfigPath
    $msg += "Add it to the INI or start the script with -LocalServerCode."
    throw $msg
}

function Get-SourceRoot {
    <# Builds the source root for a given server code, e.g. \\HOST\E$\Data\se-iciq #>
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)][string]$ServerCode)

    $envName = $Config.ServerEnvironment[$ServerCode]
    $template = $Config.SourceRootTemplate
    if ($Config.SourceRootOverrides.ContainsKey($envName)) {
        $template = $Config.SourceRootOverrides[$envName]
    }
    $hostValue = $Config.ServerHost[$ServerCode]
    $root = $template.Replace('{SERVER}', $hostValue).Replace('{CODE}', $ServerCode)
    return (ConvertTo-NativePath $root).TrimEnd('\', '/')
}

# ---------------------------------------------------------------------------
# region Include / exclude rules
# ---------------------------------------------------------------------------

function Test-FileExclusion {
    <#
        Decides whether a path relative to the source root must be skipped.
        Pattern semantics:
          "Se-common\bat\Recov_Temp\"  trailing separator -> the folder and everything below it
          "Se-common\bat\CFT_ACK.log"  contains a separator -> matched against the whole
                                       relative path (wildcards allowed, * spans separators)
          "*.tmp"                      no separator -> matched against the file name alone
        MatchExcludeAtAnyDepth also matches multi-segment patterns further down the tree
        (so "temp\*" catches "Se-common\temp\x.log" as well).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)]$Patterns,
        [bool]$MatchAtAnyDepth = $true
    )

    $rel = ($RelativePath -replace '/', '\').TrimStart('\')
    if ($rel.Length -eq 0) { return $false }
    $leaf = ($rel -split '\\')[-1]

    foreach ($rawPattern in $Patterns) {
        $p = ([string]$rawPattern).Trim()
        if ($p.Length -eq 0) { continue }
        $p = ($p -replace '/', '\').TrimStart('\')

        if ($p.EndsWith('\')) {
            $prefix = $p.TrimEnd('\')
            if ($rel -like ($prefix + '\*')) { return $true }
            if ($rel -eq $prefix) { return $true }
            if ($MatchAtAnyDepth -and ($rel -like ('*\' + $prefix + '\*'))) { return $true }
            continue
        }

        if ($p.Contains('\')) {
            if ($rel -like $p) { return $true }
            if ($rel -like ($p + '\*')) { return $true }
            if ($MatchAtAnyDepth) {
                if ($rel -like ('*\' + $p)) { return $true }
                if ($rel -like ('*\' + $p + '\*')) { return $true }
            }
            continue
        }

        if ($leaf -like $p) { return $true }
    }

    return $false
}

function Get-IncludeTarget {
    <#
        Expands one [INCLUDE] entry into the files it designates on a given source root.
        A trailing separator, or a path that resolves to a directory, means "recurse".
        Anything else is treated as a single explicitly listed file.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$Entry
    )

    $isFolderEntry = $Entry.EndsWith('\') -or $Entry.EndsWith('/')
    $rel = $Entry.TrimEnd('\', '/')
    $full = Join-NativePath -Base $SourceRoot -Relative $rel

    $out = [pscustomobject]@{
        Entry          = $Entry
        RelativeRoot   = ($rel -replace '/', '\')
        Exists         = $false
        IsExplicitFile = $false
        Files          = @()
        ErrorText      = $null
    }

    try {
        if (-not (Test-Path -LiteralPath $full)) { return $out }
        $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        $out.Exists = $true

        if ($item.PSIsContainer) {
            $out.Files = @(Get-ChildItem -LiteralPath $full -File -Recurse -Force -ErrorAction Stop)
        }
        else {
            if ($isFolderEntry) {
                $out.ErrorText = "INCLUDE entry '$Entry' ends with a separator but is a file on this source."
            }
            $out.IsExplicitFile = $true
            $out.Files = @($item)
        }
    }
    catch {
        $out.ErrorText = $_.Exception.Message
    }

    return $out
}

# ---------------------------------------------------------------------------
# region Lock file
# ---------------------------------------------------------------------------

function Enter-SyncLock {
    param([Parameter(Mandatory = $true)]$Config)

    $lockPath = $Config.LockFilePath
    $dir = Split-Path -Parent $lockPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if (Test-Path -LiteralPath $lockPath) {
        $stale = $false
        $reason = ''
        try {
            $content = Get-Content -LiteralPath $lockPath -Raw -ErrorAction Stop
            $lockPid = $null
            $lockTime = $null
            if ($content -match 'PID=(\d+)') { $lockPid = [int]$matches[1] }
            if ($content -match 'Started=([0-9\-: ]+)') {
                $parsed = [datetime]::MinValue
                if ([datetime]::TryParse($matches[1].Trim(), [ref]$parsed)) { $lockTime = $parsed }
            }

            if ($null -ne $lockPid) {
                $proc = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
                if ($null -eq $proc) {
                    $stale = $true
                    $reason = "owning process $lockPid is gone"
                }
            }
            if (-not $stale -and $null -ne $lockTime -and
                ((Get-Date) - $lockTime).TotalMinutes -gt $Config.LockTimeoutMinutes) {
                $stale = $true
                $reason = "lock older than $($Config.LockTimeoutMinutes) minutes"
            }
        }
        catch {
            $stale = $true
            $reason = "lock file unreadable"
        }

        if (-not $stale) {
            return $false
        }

        Write-SyncLog -Action 'LOCK' -SourceFile $lockPath -Status 'WARNING' -ErrorText "Stale lock removed ($reason)"
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }

    $payload = "PID=$PID`r`nStarted=$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))`r`nServer=$($Script:LocalCode)"
    Set-Content -LiteralPath $lockPath -Value $payload -Encoding UTF8 -ErrorAction Stop
    return $true
}

function Exit-SyncLock {
    param([Parameter(Mandatory = $true)]$Config)
    try {
        if (Test-Path -LiteralPath $Config.LockFilePath) {
            Remove-Item -LiteralPath $Config.LockFilePath -Force -ErrorAction Stop
        }
    }
    catch {
        Write-SyncLog -Action 'LOCK' -Status 'WARNING' -ErrorText "Unable to remove lock file: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# region Free space
# ---------------------------------------------------------------------------

function Get-FreeSpaceMB {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $probe = $Path
        while ($probe -and -not (Test-Path -LiteralPath $probe)) {
            $parent = Split-Path -Parent $probe
            if ($parent -eq $probe) { break }
            $probe = $parent
        }
        if (-not $probe) { return -1 }
        $full = (Resolve-Path -LiteralPath $probe -ErrorAction Stop).Path
        $root = [System.IO.Path]::GetPathRoot($full)
        if ([string]::IsNullOrWhiteSpace($root)) { return -1 }
        $drive = New-Object System.IO.DriveInfo($root)
        return [math]::Round($drive.AvailableFreeSpace / 1MB)
    }
    catch {
        return -1
    }
}

# ---------------------------------------------------------------------------
# region Planning
# ---------------------------------------------------------------------------

function New-CopyPlan {
    <#
        Walks every source server of the source environment and returns the list of files
        that must be copied, plus the skip/warning decisions taken along the way.
    #>
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string[]]$SourceServers,
        [Parameter(Mandatory = $true)][bool]$Simulate
    )

    $plan = New-Object System.Collections.ArrayList
    $maxBytes = [long]$Config.MaxFileSizeMB * 1MB
    $tolerance = [double]$Config.TimestampToleranceSeconds

    foreach ($srcCode in $SourceServers) {
        $sourceRoot = Get-SourceRoot -Config $Config -ServerCode $srcCode
        $destRoot = Join-NativePath -Base $Config.DestinationBasePath -Relative $srcCode

        if (-not (Test-Path -LiteralPath $sourceRoot)) {
            Write-SyncLog -Server $srcCode -Action 'SCAN' -SourceFile $sourceRoot -DestinationServers $Script:LocalCode `
                -Status 'FAIL' -ErrorText 'Source root unreachable (network, share or permissions)'
            $Script:Stats.Errors++
            continue
        }

        foreach ($entry in $Config.Include) {
            $target = Get-IncludeTarget -SourceRoot $sourceRoot -Entry $entry

            if ($null -ne $target.ErrorText) {
                Write-SyncLog -Server $srcCode -Action 'SCAN' -SourceFile $entry -DestinationServers $Script:LocalCode `
                    -Status 'WARNING' -ErrorText $target.ErrorText
                $Script:Stats.Warnings++
            }
            if (-not $target.Exists) {
                # An INCLUDE folder that does not exist on every source server is normal in some
                # setups; set WarnOnMissingIncludePath = False to keep the log quiet.
                if ($Config.WarnOnMissingIncludePath) {
                    Write-SyncLog -Server $srcCode -Action 'SCAN' -SourceFile $entry -DestinationServers $Script:LocalCode `
                        -Status 'WARNING' -ErrorText 'INCLUDE path not found on source'
                    $Script:Stats.Warnings++
                }
                continue
            }

            foreach ($file in $target.Files) {
                $rel = Get-RelativePath -FullPath $file.FullName -Root $sourceRoot
                if ($rel.Length -eq 0) { continue }

                if (Test-FileExclusion -RelativePath $rel -Patterns $Config.Exclude -MatchAtAnyDepth $Config.MatchExcludeAtAnyDepth) {
                    Write-Verbose "EXCLUDED $srcCode :: $rel"
                    continue
                }

                $destPath = Join-NativePath -Base $destRoot -Relative $rel
                $destFile = $null
                if (Test-Path -LiteralPath $destPath) {
                    try { $destFile = Get-Item -LiteralPath $destPath -Force -ErrorAction Stop } catch { $destFile = $null }
                }

                # --- change detection -----------------------------------------
                $needsCopy = $false
                if ($null -eq $destFile) {
                    $needsCopy = $true
                }
                else {
                    $delta = ($file.LastWriteTimeUtc - $destFile.LastWriteTimeUtc).TotalSeconds
                    if ($delta -gt $tolerance) { $needsCopy = $true }
                    elseif ($Config.CompareFileSize -and $file.Length -ne $destFile.Length) { $needsCopy = $true }
                }
                if (-not $needsCopy) { continue }

                # --- size guard -----------------------------------------------
                $sizeWarning = $null
                if ($file.Length -gt $maxBytes) {
                    if (-not $target.IsExplicitFile) {
                        Write-SyncLog -Server $srcCode -Action 'SKIP' -SourceFile $rel -DestinationServers $Script:LocalCode `
                            -Status 'WARNING' -Size (Format-FileSize $file.Length) `
                            -ErrorText "File exceeds MaxFileSizeMB ($($Config.MaxFileSizeMB)MB)"
                        $Script:Stats.Warnings++
                        $Script:Stats.Skipped++
                        continue
                    }
                    $sizeWarning = "File exceeds MaxFileSizeMB ($($Config.MaxFileSizeMB)MB) but is listed explicitly in [INCLUDE]"
                }

                [void]$plan.Add([pscustomobject]@{
                        SourceCode        = $srcCode
                        RelativePath      = $rel
                        SourcePath        = $file.FullName
                        DestinationPath   = $destPath
                        SizeBytes         = [long]$file.Length
                        SourceLastWriteUtc = $file.LastWriteTimeUtc
                        SizeWarning       = $sizeWarning
                        MaxAttempts       = $Config.RetryCount
                        RetryDelaySeconds = $Config.RetryDelaySeconds
                        PreserveTimestamps = $Config.PreserveTimestamps
                        Simulate          = $Simulate
                    })
            }
        }
    }

    return $plan
}

# ---------------------------------------------------------------------------
# region Copy worker (runs inside the runspace pool)
# ---------------------------------------------------------------------------

$Script:CopyWorker = {
    param($Item)

    $result = [pscustomobject]@{
        SourceCode   = $Item.SourceCode
        RelativePath = $Item.RelativePath
        SizeBytes    = $Item.SizeBytes
        Status       = 'FAIL'
        ErrorText    = $null
        DurationMs   = 0
        Attempts     = 0
        DiskFull     = $false
        Permission   = $false
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    for ($attempt = 1; $attempt -le $Item.MaxAttempts; $attempt++) {
        $result.Attempts = $attempt
        try {
            if ($Item.Simulate) {
                $result.Status = 'WHATIF'
                $result.ErrorText = $null
                break
            }

            $destDir = Split-Path -Parent $Item.DestinationPath
            if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force -ErrorAction Stop | Out-Null
            }

            Copy-Item -LiteralPath $Item.SourcePath -Destination $Item.DestinationPath -Force -ErrorAction Stop

            if ($Item.PreserveTimestamps) {
                try {
                    $copied = Get-Item -LiteralPath $Item.DestinationPath -Force -ErrorAction Stop
                    $copied.LastWriteTimeUtc = $Item.SourceLastWriteUtc
                }
                catch {
                    # Non fatal: the file is there, only the timestamp could not be aligned.
                }
            }

            $result.Status = 'SUCCESS'
            $result.ErrorText = $null
            break
        }
        catch {
            $ex = $_.Exception
            $result.ErrorText = $ex.Message
            $hres = 0
            try { $hres = $ex.HResult } catch { $hres = 0 }

            $isDiskFull = ($hres -eq -2147024784) -or ($ex.Message -match 'not enough space|disk is full')
            $isPermission = ($ex -is [System.UnauthorizedAccessException]) -or ($hres -eq -2147024891) -or
                            ($ex.Message -match 'Access to the path .* is denied|Permission denied|denied')

            if ($isDiskFull) {
                $result.DiskFull = $true
                $result.Status = 'FAIL'
                break
            }
            if ($isPermission) {
                $result.Permission = $true
                $result.Status = 'FAIL'
                break
            }
            if ($attempt -lt $Item.MaxAttempts) {
                Start-Sleep -Seconds $Item.RetryDelaySeconds
                continue
            }
            $result.Status = 'FAIL'
        }
    }

    $sw.Stop()
    $result.DurationMs = [int]$sw.ElapsedMilliseconds
    return $result
}

function Invoke-CopyPlan {
    <# Executes the plan through a throttled runspace pool and logs every outcome. #>
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Plan
    )

    $outcome = [pscustomobject]@{ Copied = 0; Failed = 0; DiskFull = $false }
    if ($Plan.Count -eq 0) { return $outcome }

    $throttle = [math]::Min($Config.MaxConcurrentCopies, $Plan.Count)
    $pool = [runspacefactory]::CreateRunspacePool(1, $throttle)
    $pool.Open()
    $handles = New-Object System.Collections.ArrayList

    try {
        foreach ($item in $Plan) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($Script:CopyWorker.ToString()).AddArgument($item)
            [void]$handles.Add([pscustomobject]@{ Shell = $ps; Handle = $ps.BeginInvoke(); Item = $item })
        }

        foreach ($h in $handles) {
            $res = $null
            try {
                $res = $h.Shell.EndInvoke($h.Handle) | Select-Object -Last 1
            }
            catch {
                $res = [pscustomobject]@{
                    SourceCode = $h.Item.SourceCode; RelativePath = $h.Item.RelativePath
                    SizeBytes = $h.Item.SizeBytes; Status = 'FAIL'; ErrorText = $_.Exception.Message
                    DurationMs = 0; Attempts = 0; DiskFull = $false; Permission = $false
                }
            }
            finally {
                $h.Shell.Dispose()
            }

            if ($null -eq $res) { continue }

            $size = Format-FileSize $res.SizeBytes
            $duration = "$($res.DurationMs)ms"

            if ($res.Status -eq 'SUCCESS' -or $res.Status -eq 'WHATIF') {
                $outcome.Copied++
                $Script:Stats.Copied++
                $Script:Stats.TotalDurationMs += $res.DurationMs
                $errText = '-'
                if ($null -ne $h.Item.SizeWarning) {
                    $errText = $h.Item.SizeWarning
                    $Script:Stats.Warnings++
                }
                Write-SyncLog -Server $res.SourceCode -Action 'COPY' -SourceFile $res.RelativePath `
                    -DestinationServers $Script:LocalCode -Status $res.Status -Size $size -Duration $duration -ErrorText $errText
            }
            else {
                $outcome.Failed++
                $Script:Stats.Errors++
                if ($res.DiskFull) { $outcome.DiskFull = $true }
                $status = 'FAIL'
                if ($res.Permission -or $res.DiskFull) { $status = 'CRITICAL' }
                $err = $res.ErrorText
                if ($res.Attempts -gt 1) { $err = "$err (after $($res.Attempts) attempts)" }
                Write-SyncLog -Server $res.SourceCode -Action 'COPY' -SourceFile $res.RelativePath `
                    -DestinationServers $Script:LocalCode -Status $status -Size $size -Duration '-' -ErrorText $err
            }
        }
    }
    finally {
        $pool.Close()
        $pool.Dispose()
    }

    return $outcome
}

# ---------------------------------------------------------------------------
# region Cycle
# ---------------------------------------------------------------------------

function Invoke-SyncCycle {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string[]]$SourceServers,
        [Parameter(Mandatory = $true)][bool]$Simulate
    )

    $cycle = [pscustomobject]@{ Copied = 0; Failed = 0; DiskFull = $false; Skipped = $false }

    if (-not (Enter-SyncLock -Config $Config)) {
        Write-SyncLog -Action 'LOCK' -SourceFile $Config.LockFilePath -Status 'SKIPPED' `
            -ErrorText 'Another instance is running, cycle skipped'
        $cycle.Skipped = $true
        return $cycle
    }

    try {
        $free = Get-FreeSpaceMB -Path $Config.DestinationBasePath
        if ($free -ge 0 -and $free -lt $Config.MinFreeSpaceMB) {
            Write-SyncLog -Action 'DISK_CHECK' -SourceFile $Config.DestinationBasePath -Status 'CRITICAL' `
                -Size ("{0}MB free" -f $free) -ErrorText "Free space below MinFreeSpaceMB ($($Config.MinFreeSpaceMB)MB) - synchronization paused"
            $Script:Stats.Errors++
            $cycle.DiskFull = $true
            return $cycle
        }

        $plan = @(New-CopyPlan -Config $Config -SourceServers $SourceServers -Simulate $Simulate)
        Write-SyncLog -Action 'SCAN' -SourceFile ("{0} source server(s)" -f $SourceServers.Count) `
            -DestinationServers $Script:LocalCode -Status 'SUCCESS' -Size ("{0} file(s) to copy" -f $plan.Count)

        $res = Invoke-CopyPlan -Config $Config -Plan $plan
        $cycle.Copied = $res.Copied
        $cycle.Failed = $res.Failed
        $cycle.DiskFull = $res.DiskFull
    }
    catch {
        Write-SyncLog -Action 'CYCLE' -Status 'CRITICAL' -ErrorText "Unhandled error: $($_.Exception.Message)"
        $Script:Stats.Errors++
    }
    finally {
        Exit-SyncLock -Config $Config
    }

    return $cycle
}

# ---------------------------------------------------------------------------
# region Main
# ---------------------------------------------------------------------------

function Invoke-Main {
    $simulate = -not $PSCmdlet.ShouldProcess('destination files', 'Copy')
    # -WhatIf would otherwise also neutralize Add-Content/New-Item, i.e. the log file and
    # the lock file. Only the copies must be simulated, so the preference is reset here and
    # the simulation is carried by the $simulate flag alone.
    $Script:WhatIfPreference = $false
    $WhatIfPreference = $false

    $config = Get-SyncConfiguration -Path $ConfigPath
    Initialize-LogFile -Config $config
    Update-DailyStats -Config $config

    $Script:LocalCode = Resolve-LocalServerCode -Config $config -Override $LocalServerCode
    $localEnv = $config.ServerEnvironment[$Script:LocalCode]

    $mode = 'LIVE'
    if ($simulate) { $mode = 'WHATIF' }
    $account = [System.Environment]::UserName
    if ($env:USERDOMAIN) { $account = "$env:USERDOMAIN\$account" }
    Write-SyncLog -Action 'START' -SourceFile ("v{0}" -f $Script:ScriptVersion) -DestinationServers $Script:LocalCode `
        -Status $mode -ErrorText ("Account: {0}; PowerShell {1}" -f $account, $PSVersionTable.PSVersion)

    if (-not $config.Mapping.ContainsKey($localEnv)) {
        Write-SyncLog -Action 'START' -DestinationServers $Script:LocalCode -Status 'SKIPPED' `
            -ErrorText "Environment $localEnv has no source environment in [MAPPING] - nothing to pull."
        return 0
    }

    $sourceEnv = $config.Mapping[$localEnv]
    $sourceServers = @($config.Environments[$sourceEnv].Keys)
    if ($sourceServers.Count -eq 0) {
        Write-SyncLog -Action 'START' -DestinationServers $Script:LocalCode -Status 'FAIL' `
            -ErrorText "Source environment [$sourceEnv] contains no server."
        return 2
    }

    Write-SyncLog -Action 'CONFIG' -SourceFile $config.ConfigPath -DestinationServers $Script:LocalCode -Status 'SUCCESS' `
        -ErrorText ("{0} ({1}) pulls from {2}: {3}; interval {4}min; max {5}MB; {6} parallel" -f `
            $Script:LocalCode, $localEnv, $sourceEnv, ($sourceServers -join ','), `
            $config.SyncIntervalMinutes, $config.MaxFileSizeMB, $config.MaxConcurrentCopies)

    Remove-OldLogFile -Config $config

    $cycles = 0
    $exitCode = 0

    while ($true) {
        $cycles++
        Update-DailyStats -Config $config
        Initialize-LogFile -Config $config

        $result = Invoke-SyncCycle -Config $config -SourceServers $sourceServers -Simulate $simulate
        if ($result.Failed -gt 0) { $exitCode = 1 }

        if ($RunOnce) { break }
        if ($MaxCycles -gt 0 -and $cycles -ge $MaxCycles) { break }

        $sleepMinutes = $config.SyncIntervalMinutes
        if ($result.DiskFull) {
            $sleepMinutes = $config.DiskFullPauseMinutes
            Write-SyncLog -Action 'PAUSE' -Status 'CRITICAL' `
                -ErrorText "Disk full condition - pausing $sleepMinutes minutes, administrator action required"
        }

        $next = (Get-Date).AddMinutes($sleepMinutes)
        Write-HeartbeatLog -NextRun $next
        Start-Sleep -Seconds ($sleepMinutes * 60)
    }

    if ($RunOnce) {
        Write-HeartbeatLog -NextRun ((Get-Date).AddMinutes($config.SyncIntervalMinutes))
    }
    Write-SummaryLog -Stats $Script:Stats
    Write-SyncLog -Action 'STOP' -DestinationServers $Script:LocalCode -Status 'SUCCESS' `
        -ErrorText ("Cycles: {0}" -f $cycles)

    return $exitCode
}

if ($LoadFunctionsOnly) { return }

try {
    $code = Invoke-Main
    exit $code
}
catch {
    $msg = $_.Exception.Message
    try {
        Write-SyncLog -Action 'FATAL' -Status 'CRITICAL' -ErrorText $msg
    }
    catch { }
    Write-Error $msg
    exit 3
}
