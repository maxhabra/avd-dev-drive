# AVD Dev Drive

Create or reuse a Windows 11 Dev Drive on an Azure Virtual Desktop (AVD) session host with `New-DevDrive.ps1`.

## Defaults

| Parameter | Default |
| --- | --- |
| `VhdPath` | `C:\DevDrive\DevDrive.vhdx` |
| `DriveLetter` | `X` |
| `SizeGB` | `50` (default; minimum parameter value is 50; PowerShell GB units, 1 GB = 1,073,741,824 bytes) |
| `VolumeLabel` | `Dev Drive` |

VHDX paths used for new disks must contain only printable ASCII characters because the DiskPart command file uses ASCII encoding. Spaces are supported.

New disks are dynamically expanding VHDX files, formatted as ReFS with the Dev Drive designation. `SizeGB` specifies the exact virtual disk capacity: 50 GiB by default (51,200 MiB), with no added capacity. The data partition uses the available disk space, so it is slightly smaller than the VHDX. The parameter must be at least 50 GB; Windows validates whether the resulting volume can be formatted as a Dev Drive.

Edit the defaults in the configuration block at the top of the script, or supply them as command-line parameters. The script is organized into numbered steps with progress messages. The previous `-Path` and `-Name` parameter names remain available as aliases.

## Run

Open **64-bit PowerShell as Administrator** in the downloaded repository folder:

```powershell
# Preview checks and intended action without creating or mounting anything
.\New-DevDrive.ps1 -WhatIf

# Run with the defaults
.\New-DevDrive.ps1

# Explicit configuration
.\New-DevDrive.ps1 -VhdPath 'C:\DevDrive\DevDrive.vhdx' -DriveLetter X -SizeGB 50 -VolumeLabel 'Dev Drive'
```

The script requires PowerShell 5.1 or later and a Windows build with native Dev Drive formatting support (Windows 11 build 22621.2338 or later). Enterprise policy must permit Dev Drive. It does not enable Dev Drive through policy changes or alter antivirus settings. Hyper-V PowerShell tools and nested virtualization are not required.

## Checks and repeat runs

- Checks the **exact configured VHDX path**; unrelated VHDX files are not searched or touched.
- Checks whether the requested letter is occupied by a partition, volume, network mapping, or PowerShell drive visible to the elevated process.
- If the VHDX is already mounted at the requested letter, accepts that assignment and reports its status.
- If the letter belongs to another resource, stops before creating or mounting a VHDX.
- If the VHDX exists but is detached, attempts to attach it without automatically assigning a letter. It requires exactly one non-reserved partition containing ReFS, then assigns the requested letter. An existing different letter on that partition is replaced.
- Existing files are never initialized, resized, relabeled, or formatted. `SizeGB` and `VolumeLabel` apply only to new VHDX files.
- For new VHDX files, checks backing-volume free space (requested VHDX capacity), creates the parent folder if necessary, and formats only the newly created partition.
- Assigns the requested letter before formatting a new volume, verifies that it resolves to the exact VHDX disk and partition, then uses `format.com X: /FS:ReFS /DevDrv /Q /V:DevDrive /Y`. It checks the exit code and ReFS result before applying the requested label with `Set-Volume`. This avoids the `Format-Volume` failure observed on the tested AVD and native argument quoting problems with labels containing spaces.
- Rechecks letter availability before assignment and displays `fsutil devdrv query` output. Review that output for the volume's Dev Drive designation and trust status; ReFS alone does not establish the designation.
- Stops on errors with exit code 1. Files and attachments are retained for inspection, including after partial creation. A later run will not automatically format an incomplete VHDX.

Drive mappings in another user's session may not be visible from the elevated session. Run provisioning once per host at a time. The script does not register a startup task; rerun it to attach an existing VHDX after a reboot if necessary. Data persistence across AVD host replacement or reimaging depends on where its backing file is stored.

## Validation

Run the non-destructive parser, DiskPart command-file encoding, and drive-letter safety tests:

```powershell
.\tests\Test-Safety.ps1
```

These tests do not provision disks. Actual creation, mounting, Dev Drive status, and enterprise policy behavior still require validation on a disposable Windows 11 AVD host. Test a fresh creation, a repeat run, detach/remount, an occupied `X:`, and an existing invalid or non-ReFS VHDX before fleet deployment.

## References

- [Microsoft: Set up a Dev Drive](https://learn.microsoft.com/en-us/windows/dev-drive/)
- [Mount-DiskImage](https://learn.microsoft.com/en-us/powershell/module/storage/mount-diskimage)
- [Format-Volume](https://learn.microsoft.com/en-us/powershell/module/storage/format-volume)
- [fsutil devdrv](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/fsutil-devdrv)
