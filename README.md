# AVD Dev Drive

Automate consistent Windows 11 Dev Drive provisioning across Azure Virtual Desktop (AVD) session hosts.

Status: repository initialized; script implementation will follow after parameters are agreed.

## Proposed configuration

| Setting | Initial proposal |
| --- | --- |
| Drive letter | `X:` |
| Capacity | 50 GB (confirm exact sizing during implementation) |
| Virtual disk format | VHDX |
| File system | ReFS with the Dev Drive designation |
| Entry point | PowerShell `.ps1`, optionally a `.cmd` launcher |

These are planning values, not implemented defaults. This repository does not yet contain a provisioning script.

## Feasibility and prerequisites

Microsoft documents command-line Dev Drive formatting through PowerShell (`Format-Volume -DevDrive`) or CMD (`Format /DevDrv`). The future script will create and attach a new VHDX before formatting its new volume.

Requirements include Windows 11 build 22621.2338 or later, local administrator privileges, at least 8 GB RAM (16 GB recommended), and at least 50 GB free disk space. Enterprise policy must permit Dev Drive. Dev Drive designation is applied at format time; an existing volume cannot be converted in place.

Reference: [Microsoft: Set up a Dev Drive on Windows 11](https://learn.microsoft.com/en-us/windows/dev-drive/).

## Decisions for implementation

- VHDX directory and filename; fixed or dynamically expanding allocation.
- Volume label, exact capacity, and behavior if `X:` is already in use.
- AVD image/build and personal versus pooled or multi-session hosts.
- Per-host versus per-user storage and access permissions.
- Storage persistence across reboot, host replacement, and reimaging.
- Automatic attachment after reboot and execution/deployment method.

## Planned behavior

- Validate OS capabilities, elevation, policy, available storage, and drive-letter availability.
- Create a new VHDX and format only the volume created by the script.
- Detect existing resources so repeat runs are safe and predictable.
- Fail clearly on conflicting disks or drive letters; never overwrite an existing volume automatically.
- Report provisioning results and verify the resulting Dev Drive.
- Validate on a disposable Windows 11 AVD host before wider deployment.

AVD-specific compatibility and persistence will be validated against the target image and storage layout during implementation.
