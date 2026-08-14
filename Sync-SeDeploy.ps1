<#
.SYNOPSIS
    Synchronizes metadata files between DEV->QA and QA->PROD using timestamp comparison.

.DESCRIPTION
    Pull mechanism. The script runs on the destination server, finds out which server it is
    running on (computer name lookup in servers.ini), and pulls the changed files from the
    servers of the source environment:

        QA server   -> pulls from the DEV servers
        PROD server -> pulls from the QA servers

    Files are copied to DestinationBasePath\<source server code>\<relative path>, for
    example E:\Data\se-iciq\se-deploy\D1\Se-common\bat\script.ps1.

    Everything is configured in servers.ini, nothing is hardcoded here. Adding a server or
    an exclusion pattern means editing the INI file only.

.PARAMETER ConfigPath
    Path to servers.ini.

.PARAMETER RunOnce
    Runs one cycle and exits. Use this when the script is started by a Scheduled Task.
    Without it the script keeps running and sleeps SyncIntervalMinutes between cycles.

.PARAMETER LocalServerCode
    Forces the local server code (D1, Q1, P3, ...) instead of detecting it from the computer
    name. Needed for tests on a single machine, or if the computer name does not match the
    INI file.

.PARAMETER WhatIf
    Simulates the run without copying anything. The log is still written.

.EXAMPLE
    .\Sync-SeDeploy.ps1 -RunOnce -WhatIf

.EXAMPLE
    .\Sync-SeDeploy.ps1 -ConfigPath E:\Data\se-iciq\se-deploy\servers.ini -RunOnce

.NOTES
    Account : callssp (read on the source shares, read + write on the local destination
              folder; read on the destination is needed for the timestamp comparison)
    Written for Windows PowerShell 5.1, also works on PowerShell 7.
    Version : 1.0
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath = 'E:\Data\se-iciq\se-deploy\servers.ini',
    [switch]$RunOnce,
    [string]$LocalServerCode
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Sep = [System.IO.Path]::DirectorySeparatorChar
$Version = '1.0'

# Filled in later, used by most functions
$Script:LogFile = $null
$Script:LogDate = $null
$Script:LocalCode = $null
$Script:Stats = $null


# ---------------------------------------------------------------- INI file --

function Read-IniFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Configuration file not found: $Path"
    }

    $ini = [ordered]@{}
    $section = $null

    foreach ($rawLine in (Get-Content -LiteralPath $Path)) {

        $line = $rawLine.Trim()
        if ($line -eq '') { continue }
        if ($line.StartsWith(';') -or $line.StartsWith('#')) { continue }

        if ($line -match '^\[(.+)\]$') {
            $section = $matches[1].Trim().ToUpper()
            if (-not $ini.Contains($section)) {
                $ini[$section] = [ordered]@{
                    Keys  = [ordered]@{}
                    Items = New-Object System.Collections.ArrayList
                }
            }
            continue
        }

        if ($null -eq $section) { continue }

        # [INCLUDE] and [EXCLUDE] hold plain lines, the other sections hold key = value
        $pos = $line.IndexOf('=')
        if ($pos -gt 0) {
            $ini[$section].Keys[$line.Substring(0, $pos).Trim()] = $line.Substring($pos + 1).Trim()
        }
        else {
            [void]$ini[$section].Items.Add($line)
        }
    }

    return $ini
}

function Get-IniValue {
    param($Ini, [string]$Section, [string]$Key, $Default = $null)

    $s = $Section.ToUpper()
    if ($Ini.Contains($s) -and $Ini[$s].Keys.Contains($Key)) {
        $value = $Ini[$s].Keys[$Key]
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }
    return $Default
}

function Get-IniInt {
    param($Ini, [string]$Section, [string]$Key, [int]$Default)

    $raw = Get-IniValue $Ini $Section $Key
    if ($null -eq $raw) { return $Default }

    $number = 0
    if ([int]::TryParse(([string]$raw).Trim(), [ref]$number)) { return $number }

    Write-Warning "servers.ini: [$Section] $Key = '$raw' is not a number, default $Default is used"
    return $Default
}


# ------------------------------------------------------------------- paths --

function ConvertTo-NativePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    if ($Sep -eq '\') { return ($Path -replace '/', '\') }
    return ($Path -replace '\\', '/')
}

function Join-NativePath {
    param([string]$Base, [string]$Relative)

    $result = $Base.TrimEnd('\', '/')
    if ([string]::IsNullOrWhiteSpace($Relative)) { return $result }

    foreach ($part in ($Relative -split '[\\/]+')) {
        if ($part -ne '') { $result = $result + $Sep + $part }
    }
    return $result
}

# Path below $Root, always returned with backslashes (INI style and log style)
function Get-RelativePath {
    param([string]$FullPath, [string]$Root)

    $root = $Root.TrimEnd('\', '/')
    if ($FullPath.Length -le $root.Length) { return '' }
    return (($FullPath.Substring($root.Length).TrimStart('\', '/')) -replace '/', '\')
}


# ----------------------------------------------------------------- logging --

function Format-FileSize {
    param([long]$Bytes)

    if ($Bytes -ge 1MB) { return ('{0:N1}MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1}KB' -f ($Bytes / 1KB)) }
    return "${Bytes}B"
}

function Initialize-LogFile {
    param($Config)

    $today = (Get-Date).ToString('yyyy-MM-dd')
    if ($Script:LogDate -eq $today -and $null -ne $Script:LogFile) { return }

    if (-not (Test-Path -LiteralPath $Config.LogPath)) {
        New-Item -ItemType Directory -Path $Config.LogPath -Force | Out-Null
    }

    $Script:LogDate = $today
    $Script:LogFile = Join-NativePath $Config.LogPath "se-deploy-sync_$today.log"
}

function Write-LogLine {
    param([string]$Line)

    Write-Verbose $Line
    if ($null -eq $Script:LogFile) { return }

    # Only the main thread writes the log, but a virus scanner can still hold the file
    for ($i = 1; $i -le 3; $i++) {
        try {
            Add-Content -LiteralPath $Script:LogFile -Value $Line -Encoding UTF8 -ErrorAction Stop
            return
        }
        catch {
            if ($i -eq 3) {
                Write-Warning "Cannot write to $($Script:LogFile): $($_.Exception.Message)"
                return
            }
            Start-Sleep -Milliseconds 200
        }
    }
}

# TIMESTAMP | SERVER | ACTION | SOURCE_FILE | DESTINATION_SERVERS | STATUS | SIZE | DURATION | ERROR
# In a pull mechanism SERVER is the source server and DESTINATION_SERVERS is the local server.
function Write-SyncLog {
    param(
        [string]$Server = 'SYSTEM',
        [string]$Action,
        [string]$SourceFile = '-',
        [string]$DestinationServers = '-',
        [string]$Status = '-',
        [string]$Size = '-',
        [string]$Duration = '-',
        [string]$ErrorText = '-'
    )

    if ([string]::IsNullOrWhiteSpace($ErrorText)) { $ErrorText = '-' }
    $ErrorText = ($ErrorText -replace '[\r\n]+', ' ').Trim()

    Write-LogLine ('{0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8}' -f `
        (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Server, $Action, $SourceFile,
        $DestinationServers, $Status, $Size, $Duration, $ErrorText)
}

function Write-Heartbeat {
    param([datetime]$NextRun)

    Write-LogLine ('{0} | SYSTEM | HEARTBEAT | Script active | Next run: {1}' -f `
        (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $NextRun.ToString('HH:mm:ss'))
}

function Write-Summary {
    param($Stats, [string]$Timestamp)

    if ([string]::IsNullOrWhiteSpace($Timestamp)) {
        $Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }

    $average = 0
    if ($Stats.Copied -gt 0) { $average = [math]::Round($Stats.TotalDurationMs / $Stats.Copied) }

    Write-LogLine ('{0} | SYSTEM | SUMMARY | Files copied: {1} | Errors: {2} | Warnings: {3} | Avg duration: {4}ms' -f `
        $Timestamp, $Stats.Copied, $Stats.Errors, $Stats.Warnings, $average)
}

function New-Stats {
    param([string]$Date)

    return [pscustomobject]@{
        Date            = $Date
        Copied          = 0
        Errors          = 0
        Warnings        = 0
        TotalDurationMs = 0
    }
}

# Writes the daily summary when the date changes and starts new counters
function Update-DayCounter {
    param($Config)

    $today = (Get-Date).ToString('yyyy-MM-dd')

    if ($null -eq $Script:Stats) {
        $Script:Stats = New-Stats $today
        return
    }

    if ($Script:Stats.Date -ne $today) {
        Write-Summary $Script:Stats "$($Script:Stats.Date) 23:59:59"
        $Script:Stats = New-Stats $today
        Initialize-LogFile $Config
        Remove-OldLog $Config
    }
}

function Remove-OldLog {
    param($Config)

    try {
        # LogRetentionDays files in total, today included
        $limit = (Get-Date).Date.AddDays(-1 * ($Config.LogRetentionDays - 1))

        $oldFiles = Get-ChildItem -LiteralPath $Config.LogPath -Filter 'se-deploy-sync_*.log' -File |
            Where-Object { $_.LastWriteTime -lt $limit }

        foreach ($file in $oldFiles) {
            Remove-Item -LiteralPath $file.FullName -Force
            Write-SyncLog -Action 'LOG_PURGE' -SourceFile $file.Name -Status 'SUCCESS'
        }
    }
    catch {
        Write-SyncLog -Action 'LOG_PURGE' -Status 'FAIL' -ErrorText $_.Exception.Message
    }
}


# ----------------------------------------------------------- configuration --

function Get-SyncConfiguration {
    param([string]$Path)

    $ini = Read-IniFile $Path

    $config = [ordered]@{
        ConfigPath                = $Path
        BasePath                  = ConvertTo-NativePath (Get-IniValue $ini 'GLOBAL' 'BasePath' 'E:\Data\se-iciq\')
        DestinationBasePath       = ConvertTo-NativePath (Get-IniValue $ini 'GLOBAL' 'DestinationBasePath' 'E:\Data\se-iciq\se-deploy\')
        LogPath                   = ConvertTo-NativePath (Get-IniValue $ini 'GLOBAL' 'LogPath' 'E:\Data\se-iciq\se-deploy\Logs\')
        SourceRootTemplate        = Get-IniValue $ini 'GLOBAL' 'SourceRootTemplate' '{SERVER}\E$\Data\se-iciq'
        LogRetentionDays          = Get-IniInt $ini 'GLOBAL' 'LogRetentionDays' 7
        SyncIntervalMinutes       = Get-IniInt $ini 'GLOBAL' 'SyncIntervalMinutes' 10
        MaxFileSizeMB             = Get-IniInt $ini 'GLOBAL' 'MaxFileSizeMB' 100
        MaxConcurrentCopies       = Get-IniInt $ini 'GLOBAL' 'MaxConcurrentCopies' 4
        RetryCount                = Get-IniInt $ini 'GLOBAL' 'RetryCount' 3
        RetryDelaySeconds         = Get-IniInt $ini 'GLOBAL' 'RetryDelaySeconds' 5
        MinFreeSpaceMB            = Get-IniInt $ini 'GLOBAL' 'MinFreeSpaceMB' 1024
        LockTimeoutMinutes        = Get-IniInt $ini 'GLOBAL' 'LockTimeoutMinutes' 60
        RobocopyThreads           = Get-IniInt $ini 'GLOBAL' 'MaxConcurrentCopies' 4
        MirrorDeletions           = (Get-IniValue $ini 'GLOBAL' 'MirrorDeletions' 'False') -match '^(?i)(true|yes|1)$'
        Environments              = [ordered]@{}
        ServerEnvironment         = @{}
        ServerHost                = [ordered]@{}
        ServerComputerName        = @{}
        SourceRootPerEnvironment  = @{}
        Mapping                   = @{}
        Include                   = New-Object System.Collections.ArrayList
        Exclude                   = New-Object System.Collections.ArrayList
    }

    foreach ($environment in @('DEV', 'QA', 'PROD')) {
        $servers = [ordered]@{}
        if ($ini.Contains($environment)) {
            foreach ($key in $ini[$environment].Keys.Keys) {
                $code = $key.Trim().ToUpper()
                $servers[$code] = $ini[$environment].Keys[$key].Trim()
                $config.ServerEnvironment[$code] = $environment
                $config.ServerHost[$code] = $ini[$environment].Keys[$key].Trim()
            }
        }
        $config.Environments[$environment] = $servers
    }

    # destination environment = source environment
    $config.Mapping['QA'] = 'DEV'
    $config.Mapping['PROD'] = 'QA'
    if ($ini.Contains('MAPPING')) {
        foreach ($key in $ini['MAPPING'].Keys.Keys) {
            $config.Mapping[$key.Trim().ToUpper()] = $ini['MAPPING'].Keys[$key].Trim().ToUpper()
        }
    }

    # DEV to DEV, QA to QA and PROD to PROD must never happen
    foreach ($key in @($config.Mapping.Keys)) {
        if ($config.Mapping[$key] -eq $key) {
            throw "servers.ini [MAPPING]: '$key = $key' would synchronize an environment with itself."
        }
    }

    # The computer name of the servers is not the same as the alias used for the share,
    # so [HOSTNAMES] gives the real name used to recognize the local machine.
    if ($ini.Contains('HOSTNAMES')) {
        foreach ($key in $ini['HOSTNAMES'].Keys.Keys) {
            $code = $key.Trim().ToUpper()
            if (-not $config.ServerEnvironment.ContainsKey($code)) {
                throw "servers.ini [HOSTNAMES]: '$code' is not defined in [DEV], [QA] or [PROD]."
            }
            $config.ServerComputerName[$code] = $ini['HOSTNAMES'].Keys[$key].Trim()
        }
    }

    if ($ini.Contains('SOURCEROOT')) {
        foreach ($key in $ini['SOURCEROOT'].Keys.Keys) {
            $config.SourceRootPerEnvironment[$key.Trim().ToUpper()] = $ini['SOURCEROOT'].Keys[$key].Trim()
        }
    }

    foreach ($section in @('INCLUDE', 'EXCLUDE')) {
        if (-not $ini.Contains($section)) { continue }
        foreach ($item in $ini[$section].Items) {
            $value = ([string]$item).Trim()
            if ($value -eq '') { continue }
            if ($section -eq 'INCLUDE') { [void]$config.Include.Add($value) }
            else { [void]$config.Exclude.Add($value) }
        }
    }

    if ($config.Include.Count -eq 0) {
        throw 'servers.ini: [INCLUDE] is empty, nothing would be synchronized.'
    }

    if ($config.MaxConcurrentCopies -lt 1) { $config.MaxConcurrentCopies = 1 }
    if ($config.RetryCount -lt 1) { $config.RetryCount = 1 }
    if ($config.SyncIntervalMinutes -lt 1) { $config.SyncIntervalMinutes = 1 }

    $config.LockFile = Join-NativePath $config.DestinationBasePath 'se-deploy-sync.lock'

    return [pscustomobject]$config
}

function Resolve-LocalServerCode {
    param($Config, [string]$Override)

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        $code = $Override.Trim().ToUpper()
        if (-not $Config.ServerEnvironment.ContainsKey($code)) {
            throw "Server code '$code' is not defined in the [DEV], [QA] or [PROD] section of $($Config.ConfigPath)."
        }
        return $code
    }

    $localNames = New-Object System.Collections.ArrayList
    if ($env:COMPUTERNAME) { [void]$localNames.Add($env:COMPUTERNAME) }
    try { [void]$localNames.Add([System.Net.Dns]::GetHostName()) } catch { }

    # first the real computer names of [HOSTNAMES]
    foreach ($code in $Config.ServerComputerName.Keys) {
        $iniName = ($Config.ServerComputerName[$code] -split '\.')[0]

        foreach ($name in $localNames) {
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if (($name -split '\.')[0] -eq $iniName) { return $code }
        }
    }

    # then the alias of [DEV] / [QA] / [PROD], in case both are the same on some servers
    foreach ($code in $Config.ServerHost.Keys) {
        $iniHost = $Config.ServerHost[$code].TrimStart('\\', '/')
        $iniShortName = ($iniHost -split '\.')[0]

        foreach ($name in $localNames) {
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if (($name -split '\.')[0] -eq $iniShortName -or $name -eq $iniHost) { return $code }
        }
    }

    throw ("This computer ($($localNames -join ', ')) is not defined in $($Config.ConfigPath). " +
           "Add it to the [HOSTNAMES] section or start the script with -LocalServerCode.")
}

# \\SYQDDWHDEV1.res.sys.shared.fortis + template -> \\SYQDDWHDEV1.res.sys.shared.fortis\E$\Data\se-iciq
function Get-SourceRoot {
    param($Config, [string]$ServerCode)

    $environment = $Config.ServerEnvironment[$ServerCode]

    $template = $Config.SourceRootTemplate
    if ($Config.SourceRootPerEnvironment.ContainsKey($environment)) {
        $template = $Config.SourceRootPerEnvironment[$environment]
    }

    return (ConvertTo-NativePath $template.Replace('{SERVER}', $Config.ServerHost[$ServerCode])).TrimEnd('\', '/')
}


# ------------------------------------------------------- include / exclude --

<#
    Patterns are relative to the source root:
        Se-common\bat\Recov_Temp\   the folder and everything below it
        Se-common\bat\CFT_ACK.log   this file only
        *.tmp                       file name, at any level
        temp\*                      a folder named temp, at any level
#>
function Test-FileExclusion {
    param([string]$RelativePath, $Patterns)

    $path = ($RelativePath -replace '/', '\').TrimStart('\')
    if ($path -eq '') { return $false }
    $fileName = ($path -split '\\')[-1]

    foreach ($rawPattern in $Patterns) {

        $pattern = ([string]$rawPattern).Trim()
        if ($pattern -eq '') { continue }
        $pattern = ($pattern -replace '/', '\').TrimStart('\')

        if ($pattern.EndsWith('\')) {
            $folder = $pattern.TrimEnd('\')
            if ($path -eq $folder) { return $true }
            if ($path -like "$folder\*") { return $true }
            if ($path -like "*\$folder\*") { return $true }
            continue
        }

        if ($pattern.Contains('\')) {
            if ($path -like $pattern) { return $true }
            if ($path -like "$pattern\*") { return $true }
            if ($path -like "*\$pattern") { return $true }
            if ($path -like "*\$pattern\*") { return $true }
            continue
        }

        if ($fileName -like $pattern) { return $true }
    }

    return $false
}

# --------------------------------------------------------------- lock file --

function Enter-SyncLock {
    param($Config)

    $lockFile = $Config.LockFile
    $folder = Split-Path -Parent $lockFile
    if ($folder -and -not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }

    if (Test-Path -LiteralPath $lockFile) {

        $isStale = $false
        $reason = ''

        try {
            $content = Get-Content -LiteralPath $lockFile -Raw

            $lockPid = $null
            if ($content -match 'PID=(\d+)') { $lockPid = [int]$matches[1] }

            $lockTime = $null
            if ($content -match 'Started=([0-9\-: ]+)') {
                $parsed = [datetime]::MinValue
                if ([datetime]::TryParse($matches[1].Trim(), [ref]$parsed)) { $lockTime = $parsed }
            }

            if ($null -ne $lockPid -and $null -eq (Get-Process -Id $lockPid -ErrorAction SilentlyContinue)) {
                $isStale = $true
                $reason = "process $lockPid does not exist anymore"
            }
            elseif ($null -ne $lockTime -and ((Get-Date) - $lockTime).TotalMinutes -gt $Config.LockTimeoutMinutes) {
                $isStale = $true
                $reason = "lock older than $($Config.LockTimeoutMinutes) minutes"
            }
        }
        catch {
            $isStale = $true
            $reason = 'lock file not readable'
        }

        if (-not $isStale) { return $false }

        Write-SyncLog -Action 'LOCK' -SourceFile $lockFile -Status 'WARNING' -ErrorText "Stale lock removed ($reason)"
        Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
    }

    Set-Content -LiteralPath $lockFile -Encoding UTF8 -Value @"
PID=$PID
Started=$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
Server=$($Script:LocalCode)
"@

    return $true
}

function Exit-SyncLock {
    param($Config)

    try {
        if (Test-Path -LiteralPath $Config.LockFile) {
            Remove-Item -LiteralPath $Config.LockFile -Force
        }
    }
    catch {
        Write-SyncLog -Action 'LOCK' -Status 'WARNING' -ErrorText "Cannot delete the lock file: $($_.Exception.Message)"
    }
}


# --------------------------------------------------------------- free space --

function Get-FreeSpaceMB {
    param([string]$Path)

    try {
        # the destination folder may not exist yet, go up until we find something
        $existing = $Path
        while ($existing -and -not (Test-Path -LiteralPath $existing)) {
            $parent = Split-Path -Parent $existing
            if ($parent -eq $existing) { break }
            $existing = $parent
        }
        if (-not $existing) { return -1 }

        $root = [System.IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $existing).Path)
        if ([string]::IsNullOrWhiteSpace($root)) { return -1 }

        return [math]::Round((New-Object System.IO.DriveInfo($root)).AvailableFreeSpace / 1MB)
    }
    catch {
        return -1
    }
}

# --------------------------------------------------------- robocopy engine --

<#
    One robocopy call is prepared per source server and per [INCLUDE] entry.

    Folder entry (line ending with \) :
        robocopy <source folder> <destination folder> *.* /E [/MIR] /MAX:... /XD ... /XF ...
    Single file entry (line without \ at the end) :
        robocopy <source folder> <destination folder> <file name>
        no /MIR and no /MAX here, the file is listed by name so it is always taken.

    /MIR is only added when MirrorDeletions is True and the source folder is not empty.
    Mirroring an empty source would delete the whole destination folder, and an empty
    listing is more often a share problem than a real deletion.
#>

function ConvertTo-RobocopyFilter {
    <#
        Translates the [EXCLUDE] patterns into /XD (folders) and /XF (files) for one
        include folder. Patterns that are outside this folder are ignored for this call.
    #>
    param($Config, [string]$IncludeRelative, [string]$SourceFolder)

    $excludeDirs = New-Object System.Collections.ArrayList
    $excludeFiles = New-Object System.Collections.ArrayList

    $includePrefix = ($IncludeRelative -replace '/', '\').Trim('\')

    foreach ($rawPattern in $Config.Exclude) {

        $pattern = (([string]$rawPattern).Trim() -replace '/', '\').TrimStart('\')
        if ($pattern -eq '') { continue }

        $isFolder = $pattern.EndsWith('\')
        $pattern = $pattern.TrimEnd('\')

        # temp\* means a folder named temp, robocopy matches a bare name at any depth
        if ($pattern.EndsWith('\*')) {
            $isFolder = $true
            $pattern = $pattern.Substring(0, $pattern.Length - 2)
        }

        if (-not $pattern.Contains('\')) {
            # bare name or wildcard, robocopy applies it at any depth
            if ($isFolder) { [void]$excludeDirs.Add($pattern) }
            else { [void]$excludeFiles.Add($pattern) }
            continue
        }

        # pattern with a path: only relevant if it is inside the folder being copied
        if ($includePrefix -ne '' -and $pattern.StartsWith($includePrefix + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $below = $pattern.Substring($includePrefix.Length + 1)
            $full = Join-NativePath $SourceFolder $below
            if ($isFolder) { [void]$excludeDirs.Add($full) }
            else { [void]$excludeFiles.Add($full) }
        }
        elseif ($includePrefix -eq '') {
            $full = Join-NativePath $SourceFolder $pattern
            if ($isFolder) { [void]$excludeDirs.Add($full) }
            else { [void]$excludeFiles.Add($full) }
        }
    }

    return [pscustomobject]@{
        Directories = $excludeDirs
        Files       = $excludeFiles
    }
}

function Get-RobocopyJob {
    <# Builds the list of robocopy calls for all source servers. #>
    param($Config, [string[]]$SourceServers, [bool]$Simulate)

    $jobs = New-Object System.Collections.ArrayList
    $maxBytes = [long]$Config.MaxFileSizeMB * 1MB

    foreach ($sourceCode in $SourceServers) {

        $sourceRoot = Get-SourceRoot $Config $sourceCode
        $destinationRoot = Join-NativePath $Config.DestinationBasePath $sourceCode

        $reachable = $false
        $reason = 'Source folder not reachable (network, share or permissions)'
        try {
            $reachable = Test-Path -LiteralPath $sourceRoot
        }
        catch {
            $reason = $_.Exception.Message
        }

        if (-not $reachable) {
            Write-SyncLog -Server $sourceCode -Action 'SCAN' -SourceFile $sourceRoot `
                -DestinationServers $Script:LocalCode -Status 'FAIL' -ErrorText $reason
            $Script:Stats.Errors++
            continue
        }

        foreach ($entry in $Config.Include) {

            $isFolderEntry = $entry.EndsWith('\') -or $entry.EndsWith('/')
            $relative = $entry.TrimEnd('\', '/')
            $sourcePath = Join-NativePath $sourceRoot $relative

            if (-not (Test-Path -LiteralPath $sourcePath)) {
                Write-SyncLog -Server $sourceCode -Action 'SCAN' -SourceFile $entry `
                    -DestinationServers $Script:LocalCode -Status 'WARNING' `
                    -ErrorText 'INCLUDE path does not exist on the source server'
                $Script:Stats.Warnings++
                continue
            }

            $options = New-Object System.Collections.ArrayList
            [void]$options.AddRange(@('/COPY:DAT', '/DCOPY:T', '/BYTES', '/NP', '/NJH', '/NJS',
                    "/R:$($Config.RetryCount)", "/W:$($Config.RetryDelaySeconds)"))

            if ($Config.RobocopyThreads -gt 1) { [void]$options.Add("/MT:$($Config.RobocopyThreads)") }
            if ($Simulate) { [void]$options.Add('/L') }

            if ($isFolderEntry) {
                $sourceFolder = $sourcePath
                $destinationFolder = Join-NativePath $destinationRoot $relative
                $fileMask = @()   # no mask = *.* for robocopy, and nothing a shell could expand

                [void]$options.Add('/E')

                # mirror only when the source really has something in it
                if ($Config.MirrorDeletions) {
                    $sourceIsEmpty = $true
                    try {
                        $sourceIsEmpty = ((@(Get-ChildItem -LiteralPath $sourceFolder -File -Recurse -Force -ErrorAction Stop)).Count -eq 0)
                    }
                    catch {
                        $sourceIsEmpty = $true
                    }

                    if ($sourceIsEmpty) {
                        Write-SyncLog -Server $sourceCode -Action 'MIRROR' -SourceFile $relative `
                            -DestinationServers $Script:LocalCode -Status 'WARNING' `
                            -ErrorText 'Source folder empty or not readable, mirroring skipped for this folder (no deletion)'
                        $Script:Stats.Warnings++
                    }
                    else {
                        [void]$options.Add('/PURGE')
                    }
                }

                if ($maxBytes -gt 0) { [void]$options.Add("/MAX:$maxBytes") }

                $filter = ConvertTo-RobocopyFilter $Config $relative $sourceFolder
                if ($filter.Directories.Count -gt 0) {
                    [void]$options.Add('/XD')
                    foreach ($d in $filter.Directories) { [void]$options.Add($d) }
                }
                if ($filter.Files.Count -gt 0) {
                    [void]$options.Add('/XF')
                    foreach ($f in $filter.Files) { [void]$options.Add($f) }
                }
            }
            else {
                # single file listed by name: no mirror, no size limit
                $sourceFolder = Split-Path -Parent $sourcePath
                $destinationFolder = Split-Path -Parent (Join-NativePath $destinationRoot $relative)
                $fileMask = @((Split-Path -Leaf $sourcePath))
            }

            [void]$jobs.Add([pscustomobject]@{
                SourceCode        = $sourceCode
                SourceRoot        = $sourceRoot
                DestinationRoot   = $destinationRoot
                Entry             = $entry
                Source            = $sourceFolder
                Destination       = $destinationFolder
                FileMask          = $fileMask
                Options           = $options
                Simulate          = $Simulate
            })
        }
    }

    return $jobs
}

function Write-OversizedWarning {
    <#
        /MAX makes robocopy skip the big files silently. The requirement asks for a warning,
        so the oversized files are listed separately. Only metadata is read, nothing is copied.
    #>
    param($Config, $Job)

    if ($Config.MaxFileSizeMB -le 0) { return }
    if ($Job.FileMask.Count -gt 0) { return }   # single file entry, no size limit applies

    $maxBytes = [long]$Config.MaxFileSizeMB * 1MB

    try {
        $big = @(Get-ChildItem -LiteralPath $Job.Source -File -Recurse -Force -ErrorAction Stop |
                Where-Object { $_.Length -gt $maxBytes })
    }
    catch {
        return
    }

    foreach ($file in $big) {
        $relativePath = Get-RelativePath $file.FullName $Job.SourceRoot
        if (Test-FileExclusion $relativePath $Config.Exclude) { continue }

        Write-SyncLog -Server $Job.SourceCode -Action 'SKIP' -SourceFile $relativePath `
            -DestinationServers $Script:LocalCode -Status 'WARNING' -Size (Format-FileSize $file.Length) `
            -ErrorText "File bigger than MaxFileSizeMB ($($Config.MaxFileSizeMB)MB)"
        $Script:Stats.Warnings++
    }
}

function Invoke-RobocopyJob {
    <#
        Runs one robocopy call and turns its output into the normal log lines.
        Robocopy writes a directory header, then one line per file with the action, the
        size and the name. The action word is kept as it is in the log, so a change of
        language on the server cannot break the parsing.
    #>
    param($Config, $Job)

    $result = [pscustomobject]@{ Copied = 0; Deleted = 0; Failed = 0; ExitCode = 0 }

    $arguments = New-Object System.Collections.ArrayList
    [void]$arguments.Add($Job.Source)
    [void]$arguments.Add($Job.Destination)
    foreach ($mask in $Job.FileMask) { [void]$arguments.Add($mask) }
    foreach ($option in $Job.Options) { [void]$arguments.Add($option) }

    Write-SyncLog -Server $Job.SourceCode -Action 'ROBOCOPY' -SourceFile $Job.Entry `
        -DestinationServers $Script:LocalCode -Status 'START' `
        -ErrorText (($arguments -join ' '))

    $output = @()
    try {
        $output = @(& robocopy.exe @arguments 2>&1)
        $result.ExitCode = $LASTEXITCODE
    }
    catch {
        Write-SyncLog -Server $Job.SourceCode -Action 'ROBOCOPY' -SourceFile $Job.Entry `
            -DestinationServers $Script:LocalCode -Status 'CRITICAL' -ErrorText $_.Exception.Message
        $Script:Stats.Errors++
        $result.Failed++
        return $result
    }

    $currentFolder = $Job.Source

    foreach ($rawLine in $output) {

        $line = ([string]$rawLine).TrimEnd()
        if ($line.Trim() -eq '') { continue }

        if ($line -match 'ERROR\s+\d+') {
            Write-SyncLog -Server $Job.SourceCode -Action 'COPY' -SourceFile $Job.Entry `
                -DestinationServers $Script:LocalCode -Status 'FAIL' -ErrorText $line.Trim()
            $Script:Stats.Errors++
            $result.Failed++
            continue
        }

        # Both the folder header and the file lines look like: tab, value, tab, text.
        # The folder header is the one whose text ends with a separator.
        if ($line -notmatch '^\s*(?<action>[^\t]*?)\s*\t+\s*(?<size>\d+)\t(?<name>.+)$') { continue }

        $action = $matches['action'].Trim()
        $size = [long]$matches['size']
        $name = $matches['name'].Trim()

        if ($name.EndsWith('\') -or $name.EndsWith('/')) {
            $currentFolder = $name.TrimEnd('\', '/')
            continue
        }

        $isExtra = ($action -match '\*EXTRA')

        $fullPath = $name
        if ($name -notmatch '^(\\\\|[A-Za-z]:|/)') { $fullPath = Join-NativePath $currentFolder $name }

        # a deleted file is at the destination, the others are at the source
        $root = $Job.SourceRoot
        if ($isExtra) { $root = $Job.DestinationRoot }

        $relativePath = Get-RelativePath $fullPath $root
        if ($relativePath -eq '') { $relativePath = $name }

        $status = 'SUCCESS'
        if ($Job.Simulate) { $status = 'WHATIF' }

        if ($isExtra) {
            $result.Deleted++
            Write-SyncLog -Server $Job.SourceCode -Action 'DELETE' -SourceFile $relativePath `
                -DestinationServers $Script:LocalCode -Status $status -Size (Format-FileSize $size) `
                -ErrorText 'Not present on the source anymore'
            continue
        }

        $result.Copied++
        $Script:Stats.Copied++
        $reason = $action
        if ($reason -eq '') { $reason = 'COPY' }

        Write-SyncLog -Server $Job.SourceCode -Action 'COPY' -SourceFile $relativePath `
            -DestinationServers $Script:LocalCode -Status $status -Size (Format-FileSize $size) `
            -ErrorText $reason
    }

    # robocopy: 0 nothing to do, 1 copied, 2 extra, 4 mismatch, 8 and above is a real failure
    if ($result.ExitCode -ge 8) {
        Write-SyncLog -Server $Job.SourceCode -Action 'ROBOCOPY' -SourceFile $Job.Entry `
            -DestinationServers $Script:LocalCode -Status 'CRITICAL' `
            -ErrorText "robocopy returned $($result.ExitCode) (8 = copy error, 16 = fatal error)"
        $Script:Stats.Errors++
        $result.Failed++
    }
    else {
        Write-SyncLog -Server $Job.SourceCode -Action 'ROBOCOPY' -SourceFile $Job.Entry `
            -DestinationServers $Script:LocalCode -Status 'SUCCESS' `
            -Size ("{0} copied, {1} deleted" -f $result.Copied, $result.Deleted) `
            -ErrorText "exit code $($result.ExitCode)"
    }

    return $result
}

function Invoke-AllRobocopyJob {
    param($Config, $Jobs)

    $summary = [pscustomobject]@{ Copied = 0; Deleted = 0; Failed = 0 }

    foreach ($job in $Jobs) {
        Write-OversizedWarning $Config $job

        $result = Invoke-RobocopyJob $Config $job
        $summary.Copied += $result.Copied
        $summary.Deleted += $result.Deleted
        $summary.Failed += $result.Failed
    }

    return $summary
}

# ------------------------------------------------------------------- cycle --

function Invoke-SyncCycle {
    param($Config, [string[]]$SourceServers, [bool]$Simulate)

    $cycle = [pscustomobject]@{ Copied = 0; Deleted = 0; Failed = 0; DiskFull = $false }

    if (-not (Enter-SyncLock $Config)) {
        Write-SyncLog -Action 'LOCK' -SourceFile $Config.LockFile -Status 'SKIPPED' `
            -ErrorText 'Another instance is running, this cycle is skipped'
        return $cycle
    }

    try {
        $freeSpace = Get-FreeSpaceMB $Config.DestinationBasePath
        if ($freeSpace -ge 0 -and $freeSpace -lt $Config.MinFreeSpaceMB) {
            Write-SyncLog -Action 'DISK_CHECK' -SourceFile $Config.DestinationBasePath -Status 'CRITICAL' `
                -Size "${freeSpace}MB free" `
                -ErrorText "Free space below MinFreeSpaceMB ($($Config.MinFreeSpaceMB)MB), synchronization paused"
            $Script:Stats.Errors++
            $cycle.DiskFull = $true
            return $cycle
        }

        $jobs = @(Get-RobocopyJob $Config $SourceServers $Simulate)

        Write-SyncLog -Action 'SCAN' -SourceFile "$($SourceServers.Count) source server(s)" `
            -DestinationServers $Script:LocalCode -Status 'SUCCESS' -Size "$($jobs.Count) robocopy job(s)"

        $result = Invoke-AllRobocopyJob $Config $jobs
        $cycle.Copied = $result.Copied
        $cycle.Deleted = $result.Deleted
        $cycle.Failed = $result.Failed
    }
    catch {
        Write-SyncLog -Action 'CYCLE' -Status 'CRITICAL' -ErrorText "Unexpected error: $($_.Exception.Message)"
        $Script:Stats.Errors++
    }
    finally {
        Exit-SyncLock $Config
    }

    return $cycle
}


# -------------------------------------------------------------------- main --

function Start-Sync {

    $simulate = -not $PSCmdlet.ShouldProcess('destination files', 'Copy')

    # -WhatIf would also block Add-Content and New-Item, so the log file and the lock file
    # would not be created either. Only the copy has to be simulated.
    $Script:WhatIfPreference = $false
    $WhatIfPreference = $false

    $config = Get-SyncConfiguration $ConfigPath
    Initialize-LogFile $config
    Update-DayCounter $config

    $Script:LocalCode = Resolve-LocalServerCode $config $LocalServerCode
    $localEnvironment = $config.ServerEnvironment[$Script:LocalCode]

    $mode = 'LIVE'
    if ($simulate) { $mode = 'WHATIF' }

    $account = [System.Environment]::UserName
    if ($env:USERDOMAIN) { $account = "$env:USERDOMAIN\$account" }

    Write-SyncLog -Action 'START' -SourceFile "v$Version" -DestinationServers $Script:LocalCode -Status $mode `
        -ErrorText "Account: $account; PowerShell $($PSVersionTable.PSVersion)"

    if (-not $config.Mapping.ContainsKey($localEnvironment)) {
        Write-SyncLog -Action 'START' -DestinationServers $Script:LocalCode -Status 'SKIPPED' `
            -ErrorText "No source environment for $localEnvironment in [MAPPING], nothing to pull."
        return 0
    }

    $sourceEnvironment = $config.Mapping[$localEnvironment]
    $sourceServers = @($config.Environments[$sourceEnvironment].Keys)

    if ($sourceServers.Count -eq 0) {
        Write-SyncLog -Action 'START' -DestinationServers $Script:LocalCode -Status 'FAIL' `
            -ErrorText "Source environment [$sourceEnvironment] has no server."
        return 2
    }

    Write-SyncLog -Action 'CONFIG' -SourceFile $config.ConfigPath -DestinationServers $Script:LocalCode -Status 'SUCCESS' `
        -ErrorText ("$($Script:LocalCode) ($localEnvironment) pulls from ${sourceEnvironment}: $($sourceServers -join ',');" +
                    " interval $($config.SyncIntervalMinutes)min; max $($config.MaxFileSizeMB)MB;" +
                    " robocopy /MT:$($config.RobocopyThreads); mirror deletions: $($config.MirrorDeletions)")

    Remove-OldLog $config

    $cycleCount = 0
    $exitCode = 0

    while ($true) {

        $cycleCount++
        Update-DayCounter $config
        Initialize-LogFile $config

        $cycle = Invoke-SyncCycle $config $sourceServers $simulate
        if ($cycle.Failed -gt 0) { $exitCode = 1 }

        if ($RunOnce) { break }

        # disk full needs someone to have a look, no point in retrying every 10 minutes
        $waitMinutes = $config.SyncIntervalMinutes
        if ($cycle.DiskFull) {
            $waitMinutes = 30
            Write-SyncLog -Action 'PAUSE' -Status 'CRITICAL' `
                -ErrorText "Disk full, waiting $waitMinutes minutes, admin action needed"
        }

        Write-Heartbeat (Get-Date).AddMinutes($waitMinutes)
        Start-Sleep -Seconds ($waitMinutes * 60)
    }

    if ($RunOnce) {
        Write-Heartbeat (Get-Date).AddMinutes($config.SyncIntervalMinutes)
    }

    Write-Summary $Script:Stats
    Write-SyncLog -Action 'STOP' -DestinationServers $Script:LocalCode -Status 'SUCCESS' -ErrorText "Cycles: $cycleCount"

    return $exitCode
}


try {
    exit (Start-Sync)
}
catch {
    try { Write-SyncLog -Action 'FATAL' -Status 'CRITICAL' -ErrorText $_.Exception.Message } catch { }
    Write-Error $_.Exception.Message
    exit 3
}
