# se-deploy file synchronization

Two files:

- Sync-SeDeploy.ps1 - the script, same copy on every server
- servers.ini - all the configuration (servers, folders, limits)

Both go to E:\Data\se-iciq\se-deploy\.

## How it works

The script uses the pull mechanism described in the requirement. It runs on the
destination server, finds its own server code by comparing the computer name with the
entries in servers.ini, reads [MAPPING] to know where to pull from (QA takes from DEV,
PROD takes from QA), and copies the changed files from every server of that environment.

Files are copied into a folder named after the source server:

    on Q1:   E:\Data\se-iciq\se-deploy\D1\Se-common\bat\script.ps1
             E:\Data\se-iciq\se-deploy\D2\Se-common\bat\script.ps1
    on P1:   E:\Data\se-iciq\se-deploy\Q1\...
             E:\Data\se-iciq\se-deploy\Q2\...

A file is copied when it does not exist on the destination, when its LastWriteTime is
newer than the destination file (with a small tolerance for the clock difference between
servers), or when the size is different. No hash is calculated. After the copy the source
timestamp is applied to the destination file, otherwise the copy would look newer than the
source and everything would be copied again on the next run.

Copies run in parallel (MaxConcurrentCopies) and a lock file avoids two runs at the same
time. Since [MAPPING] is checked at startup, an environment can never be its own source,
so DEV to DEV or QA to QA cannot happen even by mistake in the INI file.

## Testing on one machine before deployment

The script does not need real servers to be tested, the server entries can point to local
folders. Create something like this:

    C:\Temp\lab\D1\Se-common\bat\...     (a few test files)
    C:\Temp\lab\D2\Se-common\bat\...
    C:\Temp\lab\Q1\

then a test INI with only these lines changed:

    [GLOBAL]
    DestinationBasePath = C:\Temp\lab\Q1\se-deploy\
    LogPath = C:\Temp\lab\Q1\se-deploy\Logs\
    SourceRootTemplate = {SERVER}
    MinFreeSpaceMB = 1

    [MAPPING]
    QA = DEV

    [DEV]
    D1 = C:\Temp\lab\D1
    D2 = C:\Temp\lab\D2

    [QA]
    Q1 = C:\Temp\lab\Q1

SourceRootTemplate = {SERVER} means the folder is taken as it is, without adding
\E$\Data\se-iciq. Keep the [INCLUDE] and [EXCLUDE] sections as they are.

Then run:

    .\Sync-SeDeploy.ps1 -ConfigPath C:\Temp\lab\servers.ini -RunOnce -LocalServerCode Q1 -WhatIf
    .\Sync-SeDeploy.ps1 -ConfigPath C:\Temp\lab\servers.ini -RunOnce -LocalServerCode Q1

-LocalServerCode is needed here because one machine plays the role of several servers.
On the real servers it is not used, the computer name is enough.

Things worth checking during the test: the second run must copy nothing, a modified file
must be copied again on the next run, the excluded files must not appear in the
destination, and -WhatIf must not create anything.

I ran this scenario plus the exclusion patterns, the oversized file case, the lock file,
the log retention and a 1000 files load test (around 10 seconds for the first copy, under
2 seconds for a run with no change).

## Deployment

1. Copy the two files to E:\Data\se-iciq\se-deploy\ on the QA and PROD servers. The DEV
   servers are only sources, they do not need the script.
2. Do the manual baseline copy DEV to QA and QA to PROD as planned, so the first run is
   not a huge one.
3. Run once with -WhatIf and check the log.
4. Create the Scheduled Task under callssp:

    schtasks /Create /TN "SE-Deploy Sync" /RU "DOMAIN\callssp" /RP * /SC MINUTE /MO 10
      /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File E:\Data\se-iciq\se-deploy\Sync-SeDeploy.ps1 -RunOnce"
      /RL LIMITED /F

Exit codes: 0 = fine, 1 = at least one file failed to copy, 3 = configuration problem
(INI not found, unknown server, wrong mapping).

If you prefer the script to run permanently instead of a Scheduled Task every 10 minutes,
remove -RunOnce and start it once at boot. It will then loop by itself and write a
heartbeat line before each pause. Both models work, but only one should be used.

## Logs

E:\Data\se-iciq\se-deploy\Logs\se-deploy-sync_YYYY-MM-DD.log, one file per day, 7 files
kept in total (today included), older ones deleted at each start and at midnight.

Format is the one from the requirement:

    2026-08-12 10:17:52 | SYSTEM | START     | v1.0 | Q1 | LIVE | - | - | Account: DOMAIN\callssp
    2026-08-12 10:17:52 | D1     | COPY      | Se-common\bat\script.ps1 | Q1 | SUCCESS  | 14B   | 87ms | -
    2026-08-12 10:17:52 | D1     | SKIP      | Se-common\bat\big.bin    | Q1 | WARNING  | 120MB | -    | File bigger than MaxFileSizeMB (100MB)
    2026-08-12 10:17:52 | D2     | COPY      | Se-common\bat\cfg.ini    | Q1 | CRITICAL | 0.5KB | -    | Access to the path ... is denied.
    2026-08-12 10:17:52 | SYSTEM | HEARTBEAT | Script active | Next run: 10:27:52
    2026-08-12 10:17:52 | SYSTEM | SUMMARY   | Files copied: 5 | Errors: 0 | Warnings: 2 | Avg duration: 46ms

One remark on the columns: with a pull mechanism the file comes from the source server and
goes to the local server only, so SERVER is the source (D1, Q2, ...) and
DESTINATION_SERVERS is the local server. In the requirement the example looks like a push
(P1 | COPY | ... | P3,P4,P9). Tell me if you prefer the two columns the other way around.

Statuses used: SUCCESS, WHATIF, WARNING, SKIPPED, FAIL (network or temporary problem,
already retried) and CRITICAL (access denied, disk full, unexpected error).

## A few details

- Exclusions: a line ending with \ excludes the folder and everything below, *.tmp matches
  the file name at any level, temp\* matches a folder named temp at any level.
  Se-common\template\ is not caught by temp\*.
- Files bigger than MaxFileSizeMB are skipped with a warning, except when the INI lists the
  file by name (like Se-temp\QSR\QSR_Excecution.log), then it is copied with a warning.
- Retries only happen on network or temporary errors. Access denied and disk full stop
  immediately, retrying them 3 times just fills the log.
- If the free space goes below MinFreeSpaceMB the cycle is skipped, a CRITICAL line is
  written and the script waits 30 minutes.
- Deletions are not propagated. A file deleted on DEV stays on QA.

## Points I need your confirmation on

1. The interval is 5 minutes at the beginning of the requirement and 10 minutes in the
   architecture part, the INI and the deployment checklist. I used 10, it is one line in
   servers.ini.

2. Max file size is 100MB in the INI section and 10MB in the risk section. I used 100.

3. The chain DEV to QA to PROD. Today DEV to QA writes into QA\se-deploy\D1, but QA to PROD
   reads the QA folders themselves (E:\Data\se-iciq\Se-common\bat). These are not the same
   folders, so a file created on D1 will never arrive on PROD by itself. Either PROD has to
   pull from the se-deploy\D1 folders of QA (there is a [SOURCEROOT] section ready for that
   in the INI, just to uncomment), or something has to move the files from se-deploy\D1
   into the QA folders. Which one do you want?

4. The INI gives the server names but no share name. I assumed the E$ administrative share,
   which means callssp must be local admin on the source servers. If not, we need a normal
   share created on the 11 servers and then only SourceRootTemplate changes.

5. The requirement says write-only access on the destination. That cannot work, comparing
   the timestamps needs read access on the destination folder too. So callssp needs read
   and write locally, and read on the source shares.

6. S3 is in the [PROD] section but points to SYQDDWHDEV3, which looks like a DEV machine.
   Can you confirm it is correct?

7. Alerts (phase 2): tell me the SMTP server, the sender, the recipients and when you want
   a mail (every CRITICAL line, or only after several failures in a row). The statuses are
   already there, it is only the sending part to add.

8. Robocopy is mentioned in the performance part but I did not use it. With small files and
   one log line per file (size, duration, status) the direct copy plus parallel execution
   gives a better log and less delay. If one day we have to move big folders, Robocopy per
   include folder would be better and I can change that part.

9. The script is written for PowerShell 5.1 and I tested it on 7. It should be run once on
   one of the real servers to confirm the 5.1 version behaves the same.
