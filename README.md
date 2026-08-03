# IQ_ENV_Deployment

Pull-based file deployment between DEV / QA / PROD environments across 11 servers.

## Files
- `IQ_ENV_Deployment.ps1` - main script (runs continuously, one instance per server)
- `servers.ini` - server / cluster definitions (deploy to `E:\Data\se-iciq\Se-Deploy\`)
- `Test-Deployment.ps1` - self-contained test harness (simulates all 11 servers locally, 18 assertions)

## How it works
Each server runs the same script under the `callssp` account and, every 5 minutes, pulls the files that are destined for it:

| Local server | Pulls from | Trigger folders scanned |
|---|---|---|
| QA (Q1, Q2) | DEV servers + the other QA server | `2QA` |
| PROD (all 7) | QA servers + other PROD servers | `2PROD`, plus `2PRODC1` or `2PRODC2` depending on cluster membership |
| DEV (D1, D2) | nothing (DEV is source only; DEV-to-DEV is excluded per requirement) | - |

Destination path: the trigger folder is removed and the path re-anchored one level above `Se-Deploy`:
`...\Se-Deploy\2QA\Se-common\bat\ABTest.bat` -> `E:\Data\se-iciq\Se-common\bat\ABTest.bat`

Completion tracking: each pulling server registers itself (with a timestamp) in a `.done` file on the **source** server under `Se-Deploy\.done\`, protected by a `.lock` file against concurrent updates. When every expected target is registered and no error occurred, the source file is deleted; the `.done` file is kept as an audit trail.

Error handling: if the destination folder does not exist, it is **not** created. The source file is renamed to `<filename>.ERROR_MISSING_DIR`, logged as FAIL, and skipped on all subsequent runs until manually corrected.

File selection excludes `.done`, `.lock`, `.log` files, previously failed `*.ERROR_*` files, and hidden/system files.

Logging: `E:\Data\se-iciq\Se-Deploy\Logs\IQ_ENV_Deployment_YYYYMMDD.log`, pipe-delimited (`timestamp|server|action|source|destinations|status|error`), auto-cleanup after 7 days.

## Running
Production (default paths, resolves its own name from servers.ini):
```powershell
powershell.exe -ExecutionPolicy Bypass -File E:\Scripts\IQ_ENV_Deployment.ps1
```
Recommended: register it as a Windows service (NSSM) or a Scheduled Task running as `callssp` at startup. Alternatively schedule it every 5 minutes with `-RunOnce` instead of the built-in loop.

Useful parameters: `-ServerName Q1` (force identity), `-RunOnce` (single cycle), `-IntervalMinutes`, `-RemoteRootTemplate` (defaults to `\\{fqdn}\E$\Data\se-iciq\Se-Deploy`).

Test locally (works with Windows PowerShell 5.1 or PowerShell 7):
```powershell
.\Test-Deployment.ps1
```

## Assumptions made - please confirm with the manager
1. **Pull chain for 2PROD**: PROD pulls from QA (and cross-copies from other PROD). Files must therefore flow DEV -> QA -> PROD; DEV -> PROD directly is covered only if someone drops the file in `2PROD` on a QA server. If PROD must also pull directly from DEV, one line in `Get-PullPlan` adds it.
2. **2DEV folder**: listed under "included files" in the requirement, but DEV-to-DEV transfer is explicitly excluded and nothing pulls from `2DEV`. Assumed unused; clarify its purpose.
3. **Remote access**: default is admin share `\\<fqdn>\E$\...`. If a dedicated share (e.g. `\\<fqdn>\se-deploy`) exists instead, adjust `-RemoteRootTemplate`.
4. **.done retention**: `.done` files are kept forever as audit trail. Add a cleanup rule if desired.
5. **servers.ini FQDNs**: the values in the requirement contained obvious typos (`I\`, `II`, commas); the sample ini normalizes them - verify before go-live.
6. **File size**: no size check is enforced ("files must be small" was treated as informational). A max-size guard can be added if needed.
