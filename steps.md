# Test of Sync-SeDeploy.ps1 in DEV/QA - step by step

## Before we start

One point to keep in mind: the script uses the pull mechanism, so it runs on the
destination server, not on the source. To test the DEV to QA transfer we log on Q1 and the
script goes and takes the files from D1 and D2.

If we run it on D1 it will do nothing and write "No source environment for DEV in
[MAPPING]" in the log. That is the normal behaviour, DEV is only a source.

Nothing is written on the DEV servers at any moment, the script only reads there. The only
thing created is a folder on Q1 that we can delete after the test.


## Step 1 - prepare

Log on Q1, if possible with the callssp account (if we use another account the permission
part of the test does not mean much).

Copy the two files into E:\Data\se-iciq\se-deploy\ :

    Sync-SeDeploy.ps1
    servers.ini

Open PowerShell and check they are there:

    cd E:\Data\se-iciq\se-deploy
    dir

And check the PowerShell version (5.1 is expected):

    $PSVersionTable.PSVersion


## Step 2 - simulation, nothing is copied

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Sync-SeDeploy.ps1 -RunOnce -WhatIf

On the screen there is only one line:

    What if: Performing the operation "Copy" on target "destination files".

That is normal, this single line is for the whole run. The details are in the log file.
No file is copied in this mode.


## Step 3 - read the log

    notepad E:\Data\se-iciq\se-deploy\Logs\se-deploy-sync_<today date>.log

Four things to look at:

    START ... | WHATIF                          -> confirms it was only a simulation
    CONFIG ... Q1 (QA) pulls from DEV: D1,D2    -> confirms the server was recognized
    SCAN ... N file(s) to copy                  -> the number of files it would copy
    COPY ... | WHATIF |                         -> the list of these files

If the list contains files we do not want, or is missing files, it is the [INCLUDE] and
[EXCLUDE] sections in servers.ini to adjust, not the script.


## Step 4 - real run

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Sync-SeDeploy.ps1 -RunOnce

Then check the files arrived:

    dir E:\Data\se-iciq\se-deploy\D1 /s
    dir E:\Data\se-iciq\se-deploy\D2 /s

In the log the lines are now SUCCESS with the size and the duration of each copy.


## Step 5 - the important test

Run exactly the same command a second time:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Sync-SeDeploy.ps1 -RunOnce

The last summary line of the log must show:

    SUMMARY | Files copied: 0 | Errors: 0

This is the test that really matters. It proves the timestamp comparison works and that the
script will not copy the same files again every 5 minutes.


## Step 6 - change detection (if we have time)

Modify a small file on D1, inside one of the folders listed in [INCLUDE], and save it.
Run the command once more. Only this file must appear in the log with COPY / SUCCESS.


## If we get an error

    "is not defined in the [DEV], [QA] or [PROD] section"
        The computer name does not match servers.ini.
        Add -LocalServerCode Q1 at the end of the command.

    "Source folder not reachable (network, share or permissions)"
        callssp cannot reach \\D1\E$. This is the share question from the README,
        we need either callssp as local admin on the source servers or a dedicated share.

    "Access to the path ... is denied" on a COPY line
        callssp has no write permission on E:\Data\se-iciq\se-deploy\ on Q1.

    "Configuration file not found"
        Wrong path, add -ConfigPath E:\Data\se-iciq\se-deploy\servers.ini

    The script does not start at all
        -ExecutionPolicy Bypass is missing in the command.

These are permission or configuration points, none of them needs a change in the script.


## After the test

To remove the test result, delete the E:\Data\se-iciq\se-deploy\D1 and \D2 folders on Q1.

Next step would be the Scheduled Task every 5 minutes under callssp, then the same two
files on the PROD servers. On PROD the script and the commands are exactly the same, the
only difference is that those servers pull from Q1 and Q2 instead of D1 and D2, and this
comes from the [MAPPING] section of the INI file.
