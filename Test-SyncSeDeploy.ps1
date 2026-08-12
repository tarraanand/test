<#
.SYNOPSIS
    Test harness for Sync-SeDeploy.ps1.

.DESCRIPTION
    Builds a throwaway lab that simulates the 11 servers as local folders, then runs
    unit tests (exclusion engine, INI parser) and end-to-end tests (first sync, idempotency,
    change detection, size guard, -WhatIf, lock file, log retention, unreachable source,
    same-environment guard, log format).

    Nothing outside -LabRoot is touched.

.EXAMPLE
    .\Test-SyncSeDeploy.ps1 -IncludeLoadTest
#>

[CmdletBinding()]
param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'Sync-SeDeploy.ps1'),
    [string]$LabRoot = (Join-Path ([System.IO.Path]::GetTempPath()) 'se-deploy-lab'),
    [switch]$IncludeLoadTest
)

$ErrorActionPreference = 'Stop'
$Sep = [System.IO.Path]::DirectorySeparatorChar
$PwshExe = Join-Path $PSHOME 'pwsh'
if (-not (Test-Path -LiteralPath $PwshExe)) { $PwshExe = 'pwsh' }

$Script:Total = 0
$Script:Passed = 0
$Script:Failures = New-Object System.Collections.ArrayList

function Assert-Condition {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    $Script:Total++
    if ($Condition) {
        $Script:Passed++
        Write-Host ("  [PASS] {0}" -f $Name) -ForegroundColor Green
    }
    else {
        [void]$Script:Failures.Add($Name)
        Write-Host ("  [FAIL] {0} {1}" -f $Name, $Detail) -ForegroundColor Red
    }
}

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    Assert-Condition -Name $Name -Condition ($Expected -eq $Actual) -Detail ("(expected '$Expected', got '$Actual')")
}

function New-LabFile {
    param([string]$Path, [string]$Content = 'x', [int]$SizeKB = 0, [datetime]$LastWrite = [datetime]::MinValue)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if ($SizeKB -gt 0) {
        $bytes = New-Object byte[] ($SizeKB * 1024)
        [System.IO.File]::WriteAllBytes($Path, $bytes)
    }
    else {
        Set-Content -LiteralPath $Path -Value $Content -Encoding UTF8
    }
    if ($LastWrite -ne [datetime]::MinValue) {
        (Get-Item -LiteralPath $Path).LastWriteTime = $LastWrite
    }
}

$ServerCodes = @('D1', 'D2', 'Q1', 'Q2', 'P1', 'P3', 'P4', 'P5', 'P6', 'P9', 'S3')

function Reset-Lab {
    if (Test-Path -LiteralPath $LabRoot) { Remove-Item -LiteralPath $LabRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $LabRoot -Force | Out-Null

    foreach ($code in $ServerCodes) {
        $root = Join-Path (Join-Path (Join-Path $LabRoot $code) 'data') 'se-iciq'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'se-deploy') -Force | Out-Null
    }

    $old = (Get-Date).AddHours(-3)

    # ---- D1: the rich case -------------------------------------------------
    $d1 = Join-Path (Join-Path (Join-Path $LabRoot 'D1') 'data') 'se-iciq'
    New-LabFile (Join-Path $d1 "Se-common${Sep}bat${Sep}script.ps1")               'write-host hi'  -LastWrite $old
    New-LabFile (Join-Path $d1 "Se-common${Sep}bat${Sep}run.bat")                  'echo hello'     -LastWrite $old
    New-LabFile (Join-Path $d1 "Se-common${Sep}bat${Sep}CFT_ACK.log")              'excluded file'  -LastWrite $old
    New-LabFile (Join-Path $d1 "Se-common${Sep}bat${Sep}scratch.tmp")              'excluded tmp'   -LastWrite $old
    New-LabFile (Join-Path $d1 "Se-common${Sep}bat${Sep}Recov_Temp${Sep}old.bat")  'excluded dir'   -LastWrite $old
    New-LabFile (Join-Path $d1 "Se-common${Sep}bat${Sep}sub${Sep}nested.bat")      'nested'         -LastWrite $old
    New-LabFile (Join-Path $d1 "Se-common${Sep}bat${Sep}big.bin")                  -SizeKB 2048     -LastWrite $old
    New-LabFile (Join-Path $d1 "Se-common${Sep}csv${Sep}data.csv")                 'a;b;c'          -LastWrite $old
    New-LabFile (Join-Path $d1 "Se-common${Sep}csv${Sep}temp${Sep}skip.csv")       'deep temp'      -LastWrite $old
    New-LabFile (Join-Path $d1 "Se-common${Sep}template${Sep}keep.csv")            'not temp'       -LastWrite $old
    New-LabFile (Join-Path $d1 "Se-Scripts${Sep}log${Sep}app.log")                 'log line'       -LastWrite $old
    New-LabFile (Join-Path $d1 "Se-temp${Sep}QSR${Sep}QSR_Excecution.log")         -SizeKB 2048     -LastWrite $old
    New-LabFile (Join-Path $d1 "Se-other${Sep}notincluded.txt")                    'never'          -LastWrite $old

    # ---- D2 ----------------------------------------------------------------
    $d2 = Join-Path (Join-Path (Join-Path $LabRoot 'D2') 'data') 'se-iciq'
    New-LabFile (Join-Path $d2 "Se-common${Sep}bat${Sep}d2script.ps1")             'd2'             -LastWrite $old
    New-LabFile (Join-Path $d2 "Se-common${Sep}csv${Sep}d2data.csv")               'd2;csv'         -LastWrite $old
    New-LabFile (Join-Path $d2 "Se-Scripts${Sep}log${Sep}d2.log")                  'd2 log'         -LastWrite $old

    # ---- Q1 / Q2 as sources for PROD ---------------------------------------
    $q1 = Join-Path (Join-Path (Join-Path $LabRoot 'Q1') 'data') 'se-iciq'
    New-LabFile (Join-Path $q1 "Se-common${Sep}bat${Sep}q1script.ps1")             'q1'             -LastWrite $old
    $q2 = Join-Path (Join-Path (Join-Path $LabRoot 'Q2') 'data') 'se-iciq'
    New-LabFile (Join-Path $q2 "Se-common${Sep}bat${Sep}q2script.ps1")             'q2'             -LastWrite $old
}

function New-LabIni {
    param(
        [string]$LocalCode,
        [hashtable]$Overrides = @{},
        [hashtable]$ServerPathOverrides = @{},
        [string]$Name = $null
    )

    if (-not $Name) { $Name = $LocalCode }
    $iniDir = Join-Path $LabRoot 'ini'
    if (-not (Test-Path -LiteralPath $iniDir)) { New-Item -ItemType Directory -Path $iniDir -Force | Out-Null }
    $iniPath = Join-Path $iniDir "$Name.ini"

    $localRoot = Join-Path (Join-Path (Join-Path $LabRoot $LocalCode) 'data') 'se-iciq'
    $globals = [ordered]@{
        BasePath                  = $localRoot
        DestinationBasePath       = (Join-Path $localRoot 'se-deploy')
        LogPath                   = (Join-Path (Join-Path $localRoot 'se-deploy') 'Logs')
        SourceRootTemplate        = "{SERVER}${Sep}data${Sep}se-iciq"
        LogRetentionDays          = 7
        SyncIntervalMinutes       = 10
        MaxFileSizeMB             = 1
        MaxConcurrentCopies       = 4
        RetryCount                = 2
        RetryDelaySeconds         = 1
        MinFreeSpaceMB            = 1
        LockTimeoutMinutes        = 60
        TimestampToleranceSeconds = 2
        CompareFileSize           = 'True'
        PreserveTimestamps        = 'True'
        MatchExcludeAtAnyDepth    = 'True'
    }
    foreach ($k in $Overrides.Keys) { $globals[$k] = $Overrides[$k] }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('[GLOBAL]')
    foreach ($k in $globals.Keys) { [void]$sb.AppendLine("$k = $($globals[$k])") }

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('[MAPPING]')
    if ($Overrides.ContainsKey('__MAPPING__')) {
        [void]$sb.AppendLine($Overrides['__MAPPING__'])
    }
    else {
        [void]$sb.AppendLine('QA = DEV')
        [void]$sb.AppendLine('PROD = QA')
    }

    $envMap = [ordered]@{
        DEV  = @('D1', 'D2')
        QA   = @('Q1', 'Q2')
        PROD = @('P1', 'P3', 'P4', 'P5', 'P6', 'P9', 'S3')
    }
    foreach ($envName in $envMap.Keys) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("[$envName]")
        foreach ($code in $envMap[$envName]) {
            $path = Join-Path $LabRoot $code
            if ($ServerPathOverrides.ContainsKey($code)) { $path = $ServerPathOverrides[$code] }
            [void]$sb.AppendLine("$code = $path")
        }
    }

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('[INCLUDE]')
    [void]$sb.AppendLine("Se-common${Sep}bat${Sep}")
    [void]$sb.AppendLine("Se-common${Sep}csv${Sep}")
    [void]$sb.AppendLine("Se-Scripts${Sep}log${Sep}")
    [void]$sb.AppendLine("Se-temp${Sep}QSR${Sep}QSR_Excecution.log")

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('[EXCLUDE]')
    [void]$sb.AppendLine("Se-common${Sep}bat${Sep}Recov_Temp${Sep}")
    [void]$sb.AppendLine("Se-common${Sep}bat${Sep}CFT_ACK.log")
    [void]$sb.AppendLine('*.tmp')
    [void]$sb.AppendLine("temp${Sep}*")

    Set-Content -LiteralPath $iniPath -Value $sb.ToString() -Encoding UTF8
    return $iniPath
}

function Invoke-Sync {
    param([string]$IniPath, [string]$LocalCode, [switch]$WhatIf)
    $args = @('-NoProfile', '-File', $ScriptPath, '-ConfigPath', $IniPath, '-RunOnce', '-LocalServerCode', $LocalCode)
    if ($WhatIf) { $args += '-WhatIf' }
    $out = & $PwshExe @args 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
}

function Get-LogContent {
    param([string]$LocalCode)
    $logDir = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $LabRoot $LocalCode) 'data') 'se-iciq') 'se-deploy') 'Logs'
    if (-not (Test-Path -LiteralPath $logDir)) { return '' }
    $today = Join-Path $logDir ("se-deploy-sync_{0}.log" -f (Get-Date).ToString('yyyy-MM-dd'))
    if (-not (Test-Path -LiteralPath $today)) { return '' }
    return (Get-Content -LiteralPath $today -Raw)
}

function Get-DestFile {
    param([string]$LocalCode, [string]$SourceCode)
    $root = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $LabRoot $LocalCode) 'data') 'se-iciq') 'se-deploy') $SourceCode
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    return @(Get-ChildItem -LiteralPath $root -File -Recurse | ForEach-Object {
            $_.FullName.Substring($root.Length).TrimStart($Sep) -replace '/', '\'
        })
}

# ===========================================================================
Write-Host "`n=== Sync-SeDeploy.ps1 test suite ===" -ForegroundColor Cyan
Write-Host "Script  : $ScriptPath"
Write-Host "Lab root: $LabRoot`n"

# --- 1. syntax check --------------------------------------------------------
Write-Host '1. Syntax and parsing' -ForegroundColor Yellow
$parseErrors = $null
$tokens = $null
[System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
Assert-Condition -Name 'Script parses without syntax errors' -Condition ($parseErrors.Count -eq 0) -Detail ($parseErrors -join '; ')

. $ScriptPath -LoadFunctionsOnly
Assert-Condition -Name 'Functions load via -LoadFunctionsOnly' -Condition ($null -ne (Get-Command Test-FileExclusion -ErrorAction SilentlyContinue))

# --- 2. exclusion engine ----------------------------------------------------
Write-Host "`n2. Exclusion engine (unit)" -ForegroundColor Yellow
$patterns = @('Se-common\bat\Recov_Temp\', 'Se-common\bat\CFT_ACK.log', '*.tmp', 'temp\*')
$cases = @(
    @{ Path = 'Se-common\bat\script.ps1';            Expected = $false; Label = 'normal file kept' },
    @{ Path = 'Se-common\bat\CFT_ACK.log';           Expected = $true;  Label = 'exact file excluded' },
    @{ Path = 'Se-common\bat\Recov_Temp\old.bat';    Expected = $true;  Label = 'folder prefix excluded' },
    @{ Path = 'Se-common\bat\Recov_Temp2\keep.bat';  Expected = $false; Label = 'similar folder name kept' },
    @{ Path = 'Se-common\bat\scratch.tmp';           Expected = $true;  Label = '*.tmp excluded' },
    @{ Path = 'Se-common\bat\sub\deep\a.tmp';        Expected = $true;  Label = '*.tmp excluded at depth' },
    @{ Path = 'temp\a.txt';                          Expected = $true;  Label = 'temp\* at root excluded' },
    @{ Path = 'Se-common\csv\temp\skip.csv';         Expected = $true;  Label = 'temp\* at depth excluded' },
    @{ Path = 'Se-common\template\keep.csv';         Expected = $false; Label = 'template\ not matched by temp\*' },
    @{ Path = 'Se-common/bat/scratch.tmp';           Expected = $true;  Label = 'forward slashes normalized' }
)
foreach ($c in $cases) {
    $actual = Test-FileExclusion -RelativePath $c.Path -Patterns $patterns -MatchAtAnyDepth $true
    Assert-Equal -Name $c.Label -Expected $c.Expected -Actual $actual
}

# --- 3. INI parser ----------------------------------------------------------
Write-Host "`n3. INI parser (unit)" -ForegroundColor Yellow
if (-not (Test-Path -LiteralPath $LabRoot)) { New-Item -ItemType Directory -Path $LabRoot -Force | Out-Null }
$malformed = Join-Path $LabRoot 'malformed.ini'
Set-Content -LiteralPath $malformed -Encoding UTF8 -Value @'
[GLOBAL]
MaxFileSizeMB = 100
; comment line
# another comment

(PROD]
P1 = \\HOST1
P3 = \\HOST3

[EXCLUDE)
*.tmp
'@
$ini = Read-IniFile -Path $malformed
Assert-Condition -Name 'Section written as (PROD] is recovered' -Condition ($ini.Contains('PROD'))
Assert-Condition -Name 'Section written as [EXCLUDE) is recovered' -Condition ($ini.Contains('EXCLUDE'))
Assert-Equal -Name 'PROD holds 2 servers' -Expected 2 -Actual $ini['PROD'].Keys.Count
Assert-Equal -Name 'GLOBAL int read correctly' -Expected 100 -Actual (Get-IniInt $ini 'GLOBAL' 'MaxFileSizeMB' 0)
Assert-Equal -Name 'Missing key falls back to default' -Expected 7 -Actual (Get-IniInt $ini 'GLOBAL' 'LogRetentionDays' 7)

# --- 4. first synchronisation ----------------------------------------------
Write-Host "`n4. First synchronisation on Q1 (pulls DEV)" -ForegroundColor Yellow
Reset-Lab
$iniQ1 = New-LabIni -LocalCode 'Q1'
$run1 = Invoke-Sync -IniPath $iniQ1 -LocalCode 'Q1'
Assert-Equal -Name 'Exit code 0' -Expected 0 -Actual $run1.ExitCode

$fromD1 = Get-DestFile -LocalCode 'Q1' -SourceCode 'D1'
$fromD2 = Get-DestFile -LocalCode 'Q1' -SourceCode 'D2'
$expectedD1 = @('Se-common\bat\script.ps1', 'Se-common\bat\run.bat', 'Se-common\bat\sub\nested.bat',
                'Se-common\csv\data.csv', 'Se-Scripts\log\app.log', 'Se-temp\QSR\QSR_Excecution.log')

foreach ($f in $expectedD1) {
    Assert-Condition -Name "D1 file copied: $f" -Condition ($fromD1 -contains $f) -Detail "(got: $($fromD1 -join ', '))"
}
Assert-Equal -Name 'D1 copied file count' -Expected $expectedD1.Count -Actual $fromD1.Count
Assert-Condition -Name 'Excluded CFT_ACK.log not copied'   -Condition (-not ($fromD1 -contains 'Se-common\bat\CFT_ACK.log'))
Assert-Condition -Name 'Excluded *.tmp not copied'         -Condition (-not ($fromD1 -contains 'Se-common\bat\scratch.tmp'))
Assert-Condition -Name 'Excluded Recov_Temp\ not copied'   -Condition (-not ($fromD1 -contains 'Se-common\bat\Recov_Temp\old.bat'))
Assert-Condition -Name 'Excluded temp\ at depth not copied' -Condition (-not ($fromD1 -contains 'Se-common\csv\temp\skip.csv'))
Assert-Condition -Name 'Oversized big.bin skipped'         -Condition (-not ($fromD1 -contains 'Se-common\bat\big.bin'))
Assert-Condition -Name 'Non-included folder not copied'    -Condition (-not ($fromD1 -contains 'Se-other\notincluded.txt'))
Assert-Equal -Name 'D2 copied file count' -Expected 3 -Actual $fromD2.Count
Assert-Condition -Name 'No same-environment folder created' -Condition (-not (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $LabRoot 'Q1') 'data') 'se-iciq') 'se-deploy') 'Q2')))

$log1 = Get-LogContent -LocalCode 'Q1'
Assert-Condition -Name 'Oversized file logged as WARNING' -Condition ($log1 -match 'SKIP \| Se-common\\bat\\big\.bin.*WARNING')
Assert-Condition -Name 'Explicit oversized INCLUDE copied with warning' -Condition ($log1 -match 'QSR_Excecution\.log.*SUCCESS.*exceeds MaxFileSizeMB')
Assert-Condition -Name 'Heartbeat line present' -Condition ($log1 -match '\| SYSTEM \| HEARTBEAT \| Script active \| Next run: \d{2}:\d{2}:\d{2}')
Assert-Condition -Name 'Daily summary line present' -Condition ($log1 -match '\| SYSTEM \| SUMMARY \| Files copied: \d+ \| Errors: \d+ \| Warnings: \d+ \| Avg duration: \d+ms')

$copyLine = @($log1 -split "`r?`n" | Where-Object { $_ -match '\| COPY \|' })[0]
Assert-Condition -Name 'COPY record has the 9 required fields' -Condition (($copyLine -split '\|').Count -eq 9) -Detail "(line: $copyLine)"
Assert-Condition -Name 'COPY record starts with a timestamp' -Condition ($copyLine -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \|')
Assert-Condition -Name 'COPY record names source and destination server' -Condition ($copyLine -match '\| (D1|D2) \| COPY \|.*\| Q1 \|')

# --- 5. idempotency ---------------------------------------------------------
Write-Host "`n5. Second run copies nothing" -ForegroundColor Yellow
Start-Sleep -Seconds 1
$run2 = Invoke-Sync -IniPath $iniQ1 -LocalCode 'Q1'
$log2 = Get-LogContent -LocalCode 'Q1'
$summaries = @([regex]::Matches($log2, 'SUMMARY \| Files copied: (\d+)'))
$lastSummary = [int]$summaries[$summaries.Count - 1].Groups[1].Value
Assert-Equal -Name 'Second cycle copied 0 files' -Expected 0 -Actual $lastSummary
Assert-Equal -Name 'Exit code still 0' -Expected 0 -Actual $run2.ExitCode

# --- 6. change detection ----------------------------------------------------
Write-Host "`n6. Change detection on LastWriteTime" -ForegroundColor Yellow
$changed = Join-Path (Join-Path (Join-Path (Join-Path $LabRoot 'D1') 'data') 'se-iciq') "Se-common${Sep}bat${Sep}script.ps1"
Set-Content -LiteralPath $changed -Value 'write-host modified' -Encoding UTF8
(Get-Item -LiteralPath $changed).LastWriteTime = (Get-Date)
$run3 = Invoke-Sync -IniPath $iniQ1 -LocalCode 'Q1'
$log3 = Get-LogContent -LocalCode 'Q1'
$summaries = @([regex]::Matches($log3, 'SUMMARY \| Files copied: (\d+)'))
$lastSummary = [int]$summaries[$summaries.Count - 1].Groups[1].Value
Assert-Equal -Name 'Only the modified file was copied' -Expected 1 -Actual $lastSummary
$destChanged = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $LabRoot 'Q1') 'data') 'se-iciq') 'se-deploy') 'D1') "Se-common${Sep}bat${Sep}script.ps1"
Assert-Condition -Name 'Destination content updated' -Condition ((Get-Content -LiteralPath $destChanged -Raw).Trim() -eq 'write-host modified')

# --- 7. WhatIf --------------------------------------------------------------
Write-Host "`n7. -WhatIf dry run" -ForegroundColor Yellow
Reset-Lab
$iniQ1 = New-LabIni -LocalCode 'Q1'
$runWhatIf = Invoke-Sync -IniPath $iniQ1 -LocalCode 'Q1' -WhatIf
$afterWhatIf = @(Get-DestFile -LocalCode 'Q1' -SourceCode 'D1')
Assert-Equal -Name 'WhatIf copied no file' -Expected 0 -Actual $afterWhatIf.Count
$logW = Get-LogContent -LocalCode 'Q1'
Assert-Condition -Name 'WhatIf actions logged with WHATIF status' -Condition ($logW -match '\| COPY \|.*\| WHATIF \|')
Assert-Condition -Name 'Start banner flags WHATIF mode' -Condition ($logW -match '\| START \|.*\| WHATIF \|')

# --- 8. PROD pulls from QA only --------------------------------------------
Write-Host "`n8. PROD server pulls QA only" -ForegroundColor Yellow
Reset-Lab
$iniP1 = New-LabIni -LocalCode 'P1'
$runP1 = Invoke-Sync -IniPath $iniP1 -LocalCode 'P1'
$p1Deploy = Join-Path (Join-Path (Join-Path (Join-Path $LabRoot 'P1') 'data') 'se-iciq') 'se-deploy'
$folders = @(Get-ChildItem -LiteralPath $p1Deploy -Directory | Where-Object { $_.Name -ne 'Logs' } | Select-Object -ExpandProperty Name)
Assert-Condition -Name 'P1 created Q1 and Q2 folders' -Condition (($folders -contains 'Q1') -and ($folders -contains 'Q2')) -Detail "(got: $($folders -join ', '))"
Assert-Condition -Name 'P1 pulled nothing from DEV' -Condition (-not ($folders -contains 'D1'))
Assert-Condition -Name 'P1 pulled nothing from another PROD server' -Condition (-not ($folders -contains 'P3'))

# --- 9. lock file -----------------------------------------------------------
Write-Host "`n9. Concurrency lock" -ForegroundColor Yellow
Reset-Lab
$iniQ1 = New-LabIni -LocalCode 'Q1'
$lockPath = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $LabRoot 'Q1') 'data') 'se-iciq') 'se-deploy') 'se-deploy-sync.lock'
New-Item -ItemType Directory -Path (Split-Path -Parent $lockPath) -Force | Out-Null
Set-Content -LiteralPath $lockPath -Encoding UTF8 -Value "PID=$PID`nStarted=$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))`nServer=Q1"
$runLocked = Invoke-Sync -IniPath $iniQ1 -LocalCode 'Q1'
$logLock = Get-LogContent -LocalCode 'Q1'
Assert-Condition -Name 'Live lock skips the cycle' -Condition ($logLock -match '\| LOCK \|.*\| SKIPPED \|')
Assert-Equal -Name 'Nothing copied while locked' -Expected 0 -Actual (@(Get-DestFile -LocalCode 'Q1' -SourceCode 'D1')).Count
Assert-Condition -Name 'Lock file preserved for the running instance' -Condition (Test-Path -LiteralPath $lockPath)

Set-Content -LiteralPath $lockPath -Encoding UTF8 -Value "PID=999999`nStarted=$((Get-Date).AddHours(-5).ToString('yyyy-MM-dd HH:mm:ss'))`nServer=Q1"
$runStale = Invoke-Sync -IniPath $iniQ1 -LocalCode 'Q1'
$logStale = Get-LogContent -LocalCode 'Q1'
Assert-Condition -Name 'Stale lock detected and removed' -Condition ($logStale -match 'Stale lock removed')
Assert-Condition -Name 'Sync resumed after stale lock' -Condition ((@(Get-DestFile -LocalCode 'Q1' -SourceCode 'D1')).Count -gt 0)
Assert-Condition -Name 'Lock released at the end of the cycle' -Condition (-not (Test-Path -LiteralPath $lockPath))

# --- 10. log retention ------------------------------------------------------
Write-Host "`n10. Log retention (7 days)" -ForegroundColor Yellow
$logDir = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $LabRoot 'Q1') 'data') 'se-iciq') 'se-deploy') 'Logs'
for ($i = 1; $i -le 12; $i++) {
    $d = (Get-Date).AddDays(-1 * $i)
    $p = Join-Path $logDir ("se-deploy-sync_{0}.log" -f $d.ToString('yyyy-MM-dd'))
    Set-Content -LiteralPath $p -Value 'old log' -Encoding UTF8
    (Get-Item -LiteralPath $p).LastWriteTime = $d
}
$runPurge = Invoke-Sync -IniPath $iniQ1 -LocalCode 'Q1'
$remaining = @(Get-ChildItem -LiteralPath $logDir -Filter 'se-deploy-sync_*.log' -File)
Assert-Condition -Name 'At most 7 log files remain' -Condition ($remaining.Count -le 7) -Detail "(got $($remaining.Count))"
Assert-Condition -Name 'Purge is logged' -Condition ((Get-LogContent -LocalCode 'Q1') -match 'LOG_PURGE')
$oldest = ($remaining | Sort-Object LastWriteTime | Select-Object -First 1)
Assert-Condition -Name 'No file older than the retention window survived' -Condition ($oldest.LastWriteTime -ge (Get-Date).Date.AddDays(-7))

# --- 11. failure handling ---------------------------------------------------
Write-Host "`n11. Failure handling" -ForegroundColor Yellow
Reset-Lab
$iniBad = New-LabIni -LocalCode 'Q1' -Name 'Q1-unreachable' -ServerPathOverrides @{ D2 = (Join-Path $LabRoot 'DOES-NOT-EXIST') }
$runBad = Invoke-Sync -IniPath $iniBad -LocalCode 'Q1'
$logBad = Get-LogContent -LocalCode 'Q1'
Assert-Condition -Name 'Unreachable source logged as FAIL' -Condition ($logBad -match '\| D2 \| SCAN \|.*\| FAIL \|.*unreachable')
Assert-Condition -Name 'Reachable source still processed' -Condition ((@(Get-DestFile -LocalCode 'Q1' -SourceCode 'D1')).Count -gt 0)

Reset-Lab
$iniLoop = New-LabIni -LocalCode 'Q1' -Name 'Q1-selfmap' -Overrides @{ '__MAPPING__' = "QA = QA`nPROD = QA" }
$runLoop = Invoke-Sync -IniPath $iniLoop -LocalCode 'Q1'
Assert-Condition -Name 'QA = QA mapping is rejected' -Condition ($runLoop.ExitCode -ne 0 -and $runLoop.Output -match 'forbidden')

$iniKnown = New-LabIni -LocalCode 'Q1' -Name 'Q1-known'
$runUnknown = Invoke-Sync -IniPath $iniKnown -LocalCode 'ZZ'
Assert-Condition -Name 'Unknown server code is rejected' -Condition ($runUnknown.ExitCode -ne 0 -and $runUnknown.Output -match 'not defined in any')

$iniMissing = Join-Path $LabRoot 'ini\nope.ini'
$runMissing = Invoke-Sync -IniPath $iniMissing -LocalCode 'Q1'
Assert-Condition -Name 'Missing INI is rejected cleanly' -Condition ($runMissing.ExitCode -ne 0 -and $runMissing.Output -match 'Configuration file not found')

# --- 12. read-only destination (permission) ---------------------------------
Write-Host "`n12. Permission failure" -ForegroundColor Yellow
Reset-Lab
$iniQ1 = New-LabIni -LocalCode 'Q1'
$destD1 = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $LabRoot 'Q1') 'data') 'se-iciq') 'se-deploy') 'D1'
New-Item -ItemType Directory -Path $destD1 -Force | Out-Null
if ($IsLinux) {
    # chmod is useless when the harness runs as root, an immutable flag is not.
    & chattr +i $destD1
    $runPerm = Invoke-Sync -IniPath $iniQ1 -LocalCode 'Q1'
    $logPerm = Get-LogContent -LocalCode 'Q1'
    Assert-Condition -Name 'Access denied logged as CRITICAL' -Condition ($logPerm -match '\| COPY \|.*\| CRITICAL \|')
    Assert-Equal -Name 'Non-zero exit code on copy failure' -Expected 1 -Actual $runPerm.ExitCode
    & chattr -i $destD1
}
else {
    Write-Host '  [SKIP] permission test only runs on Linux/macOS'
}

# --- 13. load test ----------------------------------------------------------
if ($IncludeLoadTest) {
    Write-Host "`n13. Load test (1000 files)" -ForegroundColor Yellow
    Reset-Lab
    $bulk = Join-Path (Join-Path (Join-Path (Join-Path $LabRoot 'D1') 'data') 'se-iciq') "Se-common${Sep}csv${Sep}bulk"
    New-Item -ItemType Directory -Path $bulk -Force | Out-Null
    for ($i = 1; $i -le 1000; $i++) {
        Set-Content -LiteralPath (Join-Path $bulk ("file{0:0000}.csv" -f $i)) -Value "row;$i" -Encoding UTF8
    }
    $iniQ1 = New-LabIni -LocalCode 'Q1'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $runLoad = Invoke-Sync -IniPath $iniQ1 -LocalCode 'Q1'
    $sw.Stop()
    $copied = @(Get-DestFile -LocalCode 'Q1' -SourceCode 'D1')
    Assert-Condition -Name '1000+ files copied in one cycle' -Condition ($copied.Count -ge 1000) -Detail "(got $($copied.Count))"
    Write-Host ("  [INFO] first sync of {0} files took {1:N1}s" -f $copied.Count, $sw.Elapsed.TotalSeconds) -ForegroundColor DarkGray

    $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-Sync -IniPath $iniQ1 -LocalCode 'Q1' | Out-Null
    $sw2.Stop()
    Write-Host ("  [INFO] no-change cycle over {0} files took {1:N1}s" -f $copied.Count, $sw2.Elapsed.TotalSeconds) -ForegroundColor DarkGray
}

# ===========================================================================
Write-Host "`n=== Result: $Script:Passed / $Script:Total assertions passed ===" -ForegroundColor Cyan
if ($Script:Failures.Count -gt 0) {
    Write-Host 'Failed:' -ForegroundColor Red
    $Script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host 'All tests passed.' -ForegroundColor Green
exit 0
