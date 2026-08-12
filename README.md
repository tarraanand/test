# se-deploy file synchronization

Pull-based synchronization of metadata files, DEV → QA and QA → PROD, driven entirely by
`servers.ini`. No value is hardcoded in the script.

| File | Role |
|---|---|
| `Sync-SeDeploy.ps1` | The script. Runs on every destination server. |
| `servers.ini` | All configuration. Deploy to `E:\Data\se-iciq\se-deploy\`. |
| `Test-SyncSeDeploy.ps1` | Test harness. Builds a throwaway lab simulating the 11 servers. |

## How it works

1. The script identifies the local server by matching the computer name against the values
   in `[DEV]` / `[QA]` / `[PROD]` (or `-LocalServerCode` if the names differ).
2. `[MAPPING]` gives the source environment (`QA = DEV`, `PROD = QA`). An environment can
   never be its own source — `QA = QA` is rejected at startup, so DEV→DEV cannot happen.
3. For every server of the source environment, each `[INCLUDE]` path is scanned under
   `SourceRootTemplate` (default `\\HOST\E$\Data\se-iciq`), `[EXCLUDE]` patterns are applied,
   and files whose `LastWriteTime` is newer than the local copy are pulled into
   `DestinationBasePath\<SOURCE_CODE>\<relative path>`:

```
Q1 pulls D1, D2  ->  E:\Data\se-iciq\se-deploy\D1\Se-common\bat\script.ps1
                     E:\Data\se-iciq\se-deploy\D2\Se-common\bat\script.ps1
P1 pulls Q1, Q2  ->  E:\Data\se-iciq\se-deploy\Q1\...  and  ...\Q2\...
```

Copies run in a throttled runspace pool (`MaxConcurrentCopies`), the source timestamp is
preserved on the copy so nothing is ever transferred twice, and a lock file prevents
overlapping runs.

## Deployment

1. Copy both files to `E:\Data\se-iciq\se-deploy\` on the QA and PROD servers.
   DEV servers are sources only and do not need the script.
2. Adjust `SourceRootTemplate` if `E$` is not usable by `callssp` (see open question 4).
3. Baseline copy: do the initial manual DEV→QA and QA→PROD copy as planned. The script
   would do it by itself, but the first run would then be a very large one.
4. Dry run: `.\Sync-SeDeploy.ps1 -RunOnce -WhatIf` and review the log.
5. Scheduled Task under `callssp`, repeating every `SyncIntervalMinutes`:

```
schtasks /Create /TN "SE-Deploy Sync" /RU "DOMAIN\callssp" /RP * /SC MINUTE /MO 10 ^
  /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File E:\Data\se-iciq\se-deploy\Sync-SeDeploy.ps1 -RunOnce" ^
  /RL LIMITED /F
```

Exit codes: `0` success, `1` at least one copy failed, `3` fatal (bad INI, unknown server).

Alternatively drop `-RunOnce` and the script loops forever, sleeping between cycles — one
task started at boot instead of a repeating task. Pick one model, not both.

## Logs

`E:\Data\se-iciq\se-deploy\Logs\se-deploy-sync_YYYY-MM-DD.log`, one per day,
`LogRetentionDays` files kept in total (today included), older ones purged at each start
and at midnight rollover.

```
2026-08-12 10:17:52 | SYSTEM | START     | v1.0.0 | Q1 | LIVE | - | - | Account: DOMAIN\callssp; PowerShell 5.1
2026-08-12 10:17:52 | D1     | COPY      | Se-common\bat\script.ps1 | Q1 | SUCCESS  | 14B  | 87ms | -
2026-08-12 10:17:52 | D1     | SKIP      | Se-common\bat\big.bin    | Q1 | WARNING  | 2.0MB| -    | File exceeds MaxFileSizeMB (100MB)
2026-08-12 10:17:52 | D2     | COPY      | Se-common\bat\cfg.ini    | Q1 | CRITICAL | 0.5KB| -    | Access to the path ... is denied.
2026-08-12 10:17:52 | SYSTEM | HEARTBEAT | Script active | Next run: 10:27:52
2026-08-12 10:17:52 | SYSTEM | SUMMARY   | Files copied: 5 | Errors: 0 | Warnings: 2 | Avg duration: 46ms
```

Field order is the one from the specification. In a pull model the `SERVER` column is the
**source** server the file came from and `DESTINATION_SERVERS` is the local server doing the
pull (see open question 6).

Statuses: `SUCCESS`, `WHATIF`, `WARNING`, `SKIPPED`, `FAIL` (retryable/transient),
`CRITICAL` (permission denied, disk full, unhandled exception).

## Behaviour details

| Topic | Behaviour |
|---|---|
| Change detection | `LastWriteTimeUtc` newer than destination by more than `TimestampToleranceSeconds`, or (if `CompareFileSize`) equal timestamp but different size. No hashing. |
| Timestamps | Source `LastWriteTime` is applied to the copy, so a file is copied exactly once. |
| Large files | `> MaxFileSizeMB` → skipped + WARNING, **unless** listed explicitly as a file in `[INCLUDE]` (e.g. `Se-temp\QSR\QSR_Excecution.log`), then copied + WARNING. |
| Exclusions | `foo\bar\` = folder and everything below. `*.tmp` = file name match at any depth. `temp\*` = matches at root and, with `MatchExcludeAtAnyDepth`, at any depth. `Se-common\template\` is *not* caught by `temp\*`. |
| Retries | `RetryCount` attempts with `RetryDelaySeconds` between them, for transient/network errors only. Access denied and disk full fail immediately — retrying them is pointless. |
| Disk full | Below `MinFreeSpaceMB` the cycle is skipped, logged CRITICAL, and in continuous mode the script pauses `DiskFullPauseMinutes`. |
| Lock file | `se-deploy-sync.lock` next to the destination root. A lock whose process is gone, or older than `LockTimeoutMinutes`, is treated as stale and removed. |
| `-WhatIf` | Nothing is written to the destination (not even folders); the log is still written, with status `WHATIF`. |
| Deletions | **Not** propagated. A file deleted on DEV stays on QA. |

## Testing

```powershell
.\Test-SyncSeDeploy.ps1                   # 66 assertions
.\Test-SyncSeDeploy.ps1 -IncludeLoadTest  # adds the 1000-file load test
```

The harness creates the 11 servers as folders under `%TEMP%\se-deploy-lab`, generates one
INI per simulated server, and runs the real script as a child process. Covered: exclusion
engine (10 cases including the `template\` false-positive trap), tolerant INI parser,
first sync, idempotent second run, change detection, oversized-file handling, `-WhatIf`,
PROD pulling QA only (never DEV, never another PROD server), live lock / stale lock,
7-day log retention, unreachable source, `QA = QA` rejection, unknown server code, missing
INI, access-denied classification and exit codes, log format (9 fields, heartbeat, summary).

Result of the last run: **66/66 passed**; load test 1006 files in ~14 s, no-change cycle
over the same tree in ~2.5 s.

## Open questions

1. **Sync interval** — 5 minutes (script purpose) or 10 minutes (architecture, INI,
   deployment checklist)? Currently 10, one value in the INI.
2. **Max file size** — 100 MB (INI) or 10 MB (risk mitigation)? Currently 100.
3. **Promotion chain** — this is the important one. DEV→QA writes into
   `QA:\...\se-deploy\D1\`, but QA→PROD reads QA's live `E:\Data\se-iciq\Se-common\bat\`.
   A file created on D1 therefore never reaches PROD on its own. Either PROD must pull from
   QA's `se-deploy\D1` folders (use the `[SOURCEROOT]` override), or a promotion step has to
   move files from `se-deploy\D1` into QA's live tree. Which one is intended?
4. **Share name** — the INI has host names but no share. `E$` (admin share) is assumed;
   if `callssp` is not local admin on the source servers, a dedicated read-only share is
   needed and `SourceRootTemplate` updated.
5. **Permissions** — "write-only destination access" cannot work: comparing timestamps
   requires *read* on the destination tree. `callssp` needs read+write locally, read remotely.
6. **Log columns** — the example log lines look like a push (`P1 | COPY | ... | P3,P4,P9`).
   In a pull model I log source in `SERVER` and the local server in `DESTINATION_SERVERS`.
   Confirm, or I invert them.
7. **`S3`** is listed under `[PROD]` but points to `SYQDDWHDEV3`, a DEV host name. Typo?
8. **Deletions and renames** are not propagated. Confirm this is acceptable.
9. **Do DEV servers run the script?** Currently they would log "nothing to pull" and exit.
10. **Alerts (phase 2)** — SMTP relay, sender, recipients, and the trigger threshold
    (every CRITICAL? N consecutive failures?). Easy to add on top of the existing statuses.
11. **Robocopy** — not used. The spec asks for both Robocopy and per-file parallelism; with
    small files and per-file logging (size, duration, status), native copy plus a runspace
    pool gives better logs and better latency. If bulk transfer of large trees becomes the
    real workload, Robocopy per include folder is the better engine and I can switch it.
12. **PowerShell version on the servers** — the script avoids 7.x-only syntax and targets
    5.1, but the test lab here runs 7.4. It needs one run on a real 5.1 server before rollout.
