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

    Listing, comparing, copying and deleting are done with the .NET file APIs inside the
    PowerShell process. No external program is started, so the Net-Only credentials of the
    session remain valid for every network access.

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
    Version : 2.0 - native PowerShell copy engine, robocopy removed.
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
$Version = '2.0'

# A file is considered changed when the timestamps differ by more than this. Two seconds is
# the usual tolerance, some file systems store the write time with a two second precision.
$TimeToleranceSeconds = 2

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
        RetryCount                = Get-IniInt $ini 'GLOBAL' 'RetryCount' 3
        RetryDelaySeconds         = Get-IniInt $ini 'GLOBAL' 'RetryDelaySeconds' 5
        MinFreeSpaceMB            = Get-IniInt $ini 'GLOBAL' 'MinFreeSpaceMB' 1024
        LockTimeoutMinutes        = Get-IniInt $ini 'GLOBAL' 'LockTimeoutMinutes' 60
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

# \\SYQDDWHDEV1.res.sys.shared.fortis + template -> \\SYQDDWHDEV1.res.sys.shared.fortis\iciq@iciq
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

# Folder version, used to stop walking into an excluded folder. Only the patterns that
# clearly mean a folder are used here (ending with \ or with \*), a bare file pattern such
# as *.tmp must never remove a folder.
function Test-FolderExclusion {
    param([string]$RelativePath, $Patterns)

    $path = ($RelativePath -replace '/', '\').TrimStart('\')
    if ($path -eq '') { return $false }
    $folderName = ($path -split '\\')[-1]

    foreach ($rawPattern in $Patterns) {

        $pattern = (([string]$rawPattern).Trim() -replace '/', '\').TrimStart('\')
        if ($pattern -eq '') { continue }

        if ($pattern.EndsWith('\*')) { $pattern = $pattern.Substring(0, $pattern.Length - 2) }
        elseif ($pattern.EndsWith('\')) { $pattern = $pattern.TrimEnd('\') }
        else { continue }

        if ($pattern -eq '') { continue }

        if ($pattern.Contains('\')) {
            if ($path -like $pattern) { return $true }
            if ($path -like "*\$pattern") { return $true }
        }
        elseif ($folderName -like $pattern) { return $true }
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


# ----------------------------------------------------------- copy engine --

<#
    Everything below uses System.IO only, so the copy runs inside this PowerShell process
    and keeps the credentials of the session. No external process is started.

    Get-FileTree walks a folder and returns the files and the subfolders it contains, with
    their path relative to the given root. Excluded folders are not walked at all. A folder
    that cannot be read gives a warning and sets HadError, which is what stops the deletion
    of files at the destination for that entry.
#>
function Get-FileTree {
    param([string]$Root, [string]$Folder, $Config, [string]$ServerCode)

    $result = [pscustomobject]@{
        Files    = New-Object System.Collections.ArrayList
        Folders  = New-Object System.Collections.ArrayList
        HadError = $false
    }

    $pending = New-Object System.Collections.Stack
    $pending.Push($Folder)

    while ($pending.Count -gt 0) {

        $current = $pending.Pop()

        try {
            $info = New-Object System.IO.DirectoryInfo($current)
            $subFolders = @($info.GetDirectories())
            $files = @($info.GetFiles())
        }
        catch {
            $result.HadError = $true
            Write-SyncLog -Server $ServerCode -Action 'SCAN' -SourceFile (Get-RelativePath $current $Root) `
                -DestinationServers $Script:LocalCode -Status 'WARNING' -ErrorText $_.Exception.Message
            $Script:Stats.Warnings++
            continue
        }

        foreach ($file in $files) {
            [void]$result.Files.Add([pscustomobject]@{
                Relative = Get-RelativePath $file.FullName $Root
                Info     = $file
            })
        }

        foreach ($subFolder in $subFolders) {
            $relative = Get-RelativePath $subFolder.FullName $Root
            if (Test-FolderExclusion $relative $Config.Exclude) { continue }

            [void]$result.Folders.Add($relative)
            $pending.Push($subFolder.FullName)
        }
    }

    return $result
}

# Copy needed when the file is new, when the size differs or when the write time differs
function Test-CopyNeeded {
    param($SourceInfo, $DestinationInfo)

    if (-not $DestinationInfo.Exists) { return 'New file' }
    if ($SourceInfo.Length -ne $DestinationInfo.Length) { return 'Size differs' }

    $delta = ($SourceInfo.LastWriteTimeUtc - $DestinationInfo.LastWriteTimeUtc).TotalSeconds
    if ([math]::Abs($delta) -le $TimeToleranceSeconds) { return $null }
    if ($delta -gt 0) { return 'Newer' }
    return 'Older on the source'
}

function Copy-SyncFile {
    param($Config, $SourceInfo, [string]$DestinationPath)

    $result = [pscustomobject]@{ Success = $false; ErrorText = ''; DurationMs = 0 }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()

    for ($attempt = 1; $attempt -le $Config.RetryCount; $attempt++) {

        try {
            $folder = [System.IO.Path]::GetDirectoryName($DestinationPath)
            if (-not [System.IO.Directory]::Exists($folder)) {
                [void][System.IO.Directory]::CreateDirectory($folder)
            }

            # a read only file at the destination cannot be overwritten
            $existing = New-Object System.IO.FileInfo($DestinationPath)
            if ($existing.Exists -and ($existing.Attributes -band [System.IO.FileAttributes]::ReadOnly)) {
                $existing.Attributes = $existing.Attributes -bxor [System.IO.FileAttributes]::ReadOnly
            }

            [System.IO.File]::Copy($SourceInfo.FullName, $DestinationPath, $true)

            # data, attributes and timestamps, same as the old /COPY:DAT
            $copied = New-Object System.IO.FileInfo($DestinationPath)
            $copied.Attributes = $SourceInfo.Attributes
            $copied.CreationTimeUtc = $SourceInfo.CreationTimeUtc
            $copied.LastWriteTimeUtc = $SourceInfo.LastWriteTimeUtc

            $watch.Stop()
            $result.Success = $true
            $result.DurationMs = $watch.ElapsedMilliseconds
            return $result
        }
        catch [System.UnauthorizedAccessException] {
            # rights or read only file, retrying never helps
            $result.ErrorText = $_.Exception.Message
            break
        }
        catch {
            $result.ErrorText = $_.Exception.Message
            if ($attempt -lt $Config.RetryCount) {
                Start-Sleep -Seconds $Config.RetryDelaySeconds
                continue
            }
        }
    }

    $watch.Stop()
    $result.DurationMs = $watch.ElapsedMilliseconds
    if ([string]::IsNullOrWhiteSpace($result.ErrorText)) {
        $result.ErrorText = 'Copy failed'
    }
    return $result
}

<#
    Deletes at the destination the files that are not on the source anymore, then the
    folders that became empty. Files matching an [EXCLUDE] pattern are never deleted, they
    were never copied by this script.
#>
function Remove-ExtraItem {
    param($Config, [string]$SourceCode, [string]$DestinationRoot, [string]$DestinationFolder,
          $SourceTree, [bool]$Simulate)

    $result = [pscustomobject]@{ Deleted = 0 }

    if (-not [System.IO.Directory]::Exists($DestinationFolder)) { return $result }

    $sourceFiles = @{}
    foreach ($file in $SourceTree.Files) { $sourceFiles[$file.Relative.ToUpper()] = $true }

    $sourceFolders = @{}
    foreach ($folder in $SourceTree.Folders) { $sourceFolders[$folder.ToUpper()] = $true }

    $destinationTree = Get-FileTree $DestinationRoot $DestinationFolder $Config $SourceCode
    if ($destinationTree.HadError) { return $result }

    $status = 'SUCCESS'
    if ($Simulate) { $status = 'WHATIF' }

    foreach ($file in $destinationTree.Files) {

        if ($sourceFiles.ContainsKey($file.Relative.ToUpper())) { continue }
        if (Test-FileExclusion $file.Relative $Config.Exclude) { continue }

        try {
            if (-not $Simulate) {
                $target = New-Object System.IO.FileInfo($file.Info.FullName)
                if ($target.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
                    $target.Attributes = $target.Attributes -bxor [System.IO.FileAttributes]::ReadOnly
                }
                [System.IO.File]::Delete($file.Info.FullName)
            }

            $result.Deleted++
            Write-SyncLog -Server $SourceCode -Action 'DELETE' -SourceFile $file.Relative `
                -DestinationServers $Script:LocalCode -Status $status -Size (Format-FileSize $file.Info.Length) `
                -ErrorText 'Not present on the source anymore'
        }
        catch {
            Write-SyncLog -Server $SourceCode -Action 'DELETE' -SourceFile $file.Relative `
                -DestinationServers $Script:LocalCode -Status 'FAIL' -ErrorText $_.Exception.Message
            $Script:Stats.Errors++
        }
    }

    # deepest folders first, so a folder tree is emptied from the inside out
    $extraFolders = @($destinationTree.Folders |
        Where-Object { -not $sourceFolders.ContainsKey($_.ToUpper()) } |
        Sort-Object -Property Length -Descending)

    foreach ($relative in $extraFolders) {

        $path = Join-NativePath $DestinationRoot $relative
        if (-not [System.IO.Directory]::Exists($path)) { continue }

        try {
            # only if nothing is left inside, an excluded file must keep its folder
            if (@([System.IO.Directory]::EnumerateFileSystemEntries($path)).Count -gt 0) { continue }

            if (-not $Simulate) { [System.IO.Directory]::Delete($path) }

            Write-SyncLog -Server $SourceCode -Action 'DELETE_FOLDER' -SourceFile $relative `
                -DestinationServers $Script:LocalCode -Status $status `
                -ErrorText 'Empty folder not present on the source anymore'
        }
        catch {
            Write-SyncLog -Server $SourceCode -Action 'DELETE_FOLDER' -SourceFile $relative `
                -DestinationServers $Script:LocalCode -Status 'WARNING' -ErrorText $_.Exception.Message
            $Script:Stats.Warnings++
        }
    }

    return $result
}

# One [INCLUDE] line ending with a backslash: the folder and everything below it
function Sync-FolderEntry {
    param($Config, [string]$SourceCode, [string]$SourceRoot, [string]$DestinationRoot,
          [string]$Relative, [bool]$Simulate)

    $result = [pscustomobject]@{ Copied = 0; Deleted = 0; Failed = 0 }

    $sourceFolder = Join-NativePath $SourceRoot $Relative
    $destinationFolder = Join-NativePath $DestinationRoot $Relative

    $tree = Get-FileTree $SourceRoot $sourceFolder $Config $SourceCode

    $maxBytes = [long]$Config.MaxFileSizeMB * 1MB
    $status = 'SUCCESS'
    if ($Simulate) { $status = 'WHATIF' }

    # empty folders of the source are kept, the old /E did the same
    if (-not $Simulate) {
        foreach ($folder in $tree.Folders) {
            $path = Join-NativePath $DestinationRoot $folder
            if (-not [System.IO.Directory]::Exists($path)) {
                try { [void][System.IO.Directory]::CreateDirectory($path) } catch { }
            }
        }
    }

    foreach ($file in $tree.Files) {

        if (Test-FileExclusion $file.Relative $Config.Exclude) { continue }

        if ($maxBytes -gt 0 -and $file.Info.Length -gt $maxBytes) {
            Write-SyncLog -Server $SourceCode -Action 'SKIP' -SourceFile $file.Relative `
                -DestinationServers $Script:LocalCode -Status 'WARNING' -Size (Format-FileSize $file.Info.Length) `
                -ErrorText "File bigger than MaxFileSizeMB ($($Config.MaxFileSizeMB)MB)"
            $Script:Stats.Warnings++
            continue
        }

        $destinationPath = Join-NativePath $DestinationRoot $file.Relative
        $reason = Test-CopyNeeded $file.Info (New-Object System.IO.FileInfo($destinationPath))
        if ($null -eq $reason) { continue }

        if ($Simulate) {
            $result.Copied++
            $Script:Stats.Copied++
            Write-SyncLog -Server $SourceCode -Action 'COPY' -SourceFile $file.Relative `
                -DestinationServers $Script:LocalCode -Status $status -Size (Format-FileSize $file.Info.Length) `
                -ErrorText $reason
            continue
        }

        $copy = Copy-SyncFile $Config $file.Info $destinationPath

        if ($copy.Success) {
            $result.Copied++
            $Script:Stats.Copied++
            $Script:Stats.TotalDurationMs += $copy.DurationMs
            Write-SyncLog -Server $SourceCode -Action 'COPY' -SourceFile $file.Relative `
                -DestinationServers $Script:LocalCode -Status 'SUCCESS' -Size (Format-FileSize $file.Info.Length) `
                -Duration "$($copy.DurationMs)ms" -ErrorText $reason
        }
        else {
            $result.Failed++
            $Script:Stats.Errors++
            Write-SyncLog -Server $SourceCode -Action 'COPY' -SourceFile $file.Relative `
                -DestinationServers $Script:LocalCode -Status 'FAIL' -Size (Format-FileSize $file.Info.Length) `
                -Duration "$($copy.DurationMs)ms" -ErrorText $copy.ErrorText
        }
    }

    # An empty or unreadable source is more often a share problem than a real deletion,
    # so nothing is deleted at the destination in that case.
    if ($Config.MirrorDeletions) {
        if ($tree.HadError -or $tree.Files.Count -eq 0) {
            Write-SyncLog -Server $SourceCode -Action 'MIRROR' -SourceFile $Relative `
                -DestinationServers $Script:LocalCode -Status 'WARNING' `
                -ErrorText 'Source folder empty or not readable, mirroring skipped for this folder (no deletion)'
            $Script:Stats.Warnings++
        }
        else {
            $removed = Remove-ExtraItem $Config $SourceCode $DestinationRoot $destinationFolder $tree $Simulate
            $result.Deleted = $removed.Deleted
        }
    }

    return $result
}

# One [INCLUDE] line without a backslash at the end: a single file, no size limit, no mirror
function Sync-FileEntry {
    param($Config, [string]$SourceCode, [string]$SourceRoot, [string]$DestinationRoot,
          [string]$Relative, [bool]$Simulate)

    $result = [pscustomobject]@{ Copied = 0; Deleted = 0; Failed = 0 }

    $sourcePath = Join-NativePath $SourceRoot $Relative
    $destinationPath = Join-NativePath $DestinationRoot $Relative

    $sourceInfo = New-Object System.IO.FileInfo($sourcePath)
    if (-not $sourceInfo.Exists) { return $result }

    $reason = Test-CopyNeeded $sourceInfo (New-Object System.IO.FileInfo($destinationPath))
    if ($null -eq $reason) { return $result }

    if ($Simulate) {
        $result.Copied++
        $Script:Stats.Copied++
        Write-SyncLog -Server $SourceCode -Action 'COPY' -SourceFile $Relative `
            -DestinationServers $Script:LocalCode -Status 'WHATIF' -Size (Format-FileSize $sourceInfo.Length) `
            -ErrorText $reason
        return $result
    }

    $copy = Copy-SyncFile $Config $sourceInfo $destinationPath

    if ($copy.Success) {
        $result.Copied++
        $Script:Stats.Copied++
        $Script:Stats.TotalDurationMs += $copy.DurationMs
        Write-SyncLog -Server $SourceCode -Action 'COPY' -SourceFile $Relative `
            -DestinationServers $Script:LocalCode -Status 'SUCCESS' -Size (Format-FileSize $sourceInfo.Length) `
            -Duration "$($copy.DurationMs)ms" -ErrorText $reason
    }
    else {
        $result.Failed++
        $Script:Stats.Errors++
        Write-SyncLog -Server $SourceCode -Action 'COPY' -SourceFile $Relative `
            -DestinationServers $Script:LocalCode -Status 'FAIL' -Size (Format-FileSize $sourceInfo.Length) `
            -Duration "$($copy.DurationMs)ms" -ErrorText $copy.ErrorText
    }

    return $result
}

function Sync-SourceServer {
    param($Config, [string]$SourceCode, [bool]$Simulate)

    $result = [pscustomobject]@{ Copied = 0; Deleted = 0; Failed = 0 }

    $sourceRoot = Get-SourceRoot $Config $SourceCode
    $destinationRoot = Join-NativePath $Config.DestinationBasePath $SourceCode

    $reachable = $false
    $reason = 'Source folder not reachable (network, share or permissions)'
    try {
        $reachable = [System.IO.Directory]::Exists($sourceRoot)
    }
    catch {
        $reason = $_.Exception.Message
    }

    if (-not $reachable) {
        Write-SyncLog -Server $SourceCode -Action 'SCAN' -SourceFile $sourceRoot `
            -DestinationServers $Script:LocalCode -Status 'FAIL' -ErrorText $reason
        $Script:Stats.Errors++
        $result.Failed++
        return $result
    }

    foreach ($entry in $Config.Include) {

        $isFolderEntry = $entry.EndsWith('\') -or $entry.EndsWith('/')
        $relative = $entry.TrimEnd('\', '/')
        $sourcePath = Join-NativePath $sourceRoot $relative

        $exists = $false
        try {
            if ($isFolderEntry) { $exists = [System.IO.Directory]::Exists($sourcePath) }
            else { $exists = [System.IO.File]::Exists($sourcePath) }
        }
        catch { $exists = $false }

        if (-not $exists) {
            Write-SyncLog -Server $SourceCode -Action 'SCAN' -SourceFile $entry `
                -DestinationServers $Script:LocalCode -Status 'WARNING' `
                -ErrorText 'INCLUDE path does not exist on the source server'
            $Script:Stats.Warnings++
            continue
        }

        $watch = [System.Diagnostics.Stopwatch]::StartNew()

        if ($isFolderEntry) {
            $entryResult = Sync-FolderEntry $Config $SourceCode $sourceRoot $destinationRoot $relative $Simulate
        }
        else {
            $entryResult = Sync-FileEntry $Config $SourceCode $sourceRoot $destinationRoot $relative $Simulate
        }

        $watch.Stop()

        $result.Copied += $entryResult.Copied
        $result.Deleted += $entryResult.Deleted
        $result.Failed += $entryResult.Failed

        Write-SyncLog -Server $SourceCode -Action 'SYNC' -SourceFile $entry `
            -DestinationServers $Script:LocalCode -Status 'SUCCESS' `
            -Size ("{0} copied, {1} deleted" -f $entryResult.Copied, $entryResult.Deleted) `
            -Duration "$($watch.ElapsedMilliseconds)ms" `
            -ErrorText ("{0} error(s)" -f $entryResult.Failed)
    }

    return $result
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

        Write-SyncLog -Action 'SCAN' -SourceFile "$($SourceServers.Count) source server(s)" `
            -DestinationServers $Script:LocalCode -Status 'START'

        foreach ($sourceCode in $SourceServers) {
            $result = Sync-SourceServer $Config $sourceCode $Simulate
            $cycle.Copied += $result.Copied
            $cycle.Deleted += $result.Deleted
            $cycle.Failed += $result.Failed
        }
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
                    " native PowerShell copy; mirror deletions: $($config.MirrorDeletions)")

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
