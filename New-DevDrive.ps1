#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Creates a Dev Drive or mounts the existing VHDX without formatting it.
.DESCRIPTION
Script sequence:
  - Set variables: VHDX path, drive letter, size, and volume label.
  - Check Windows and PowerShell requirements.
  - Check for an existing VHDX and ensure the drive letter is available
    (or already belongs to this VHDX).
  - Check free space when creating a new VHDX.
  - Create the folder and dynamic VHDX if needed; otherwise reuse the file.
  - Mount the VHDX if needed and identify its disk.
  - Initialize, partition, and format only a newly created VHDX as a Dev Drive.
    For an existing VHDX, inspect its partition without formatting it.
  - Recheck availability and assign the requested drive letter if needed.
  - Verify the drive and display its configuration and Dev Drive status.
.EXAMPLE
.\New-DevDrive.ps1
.EXAMPLE
.\New-DevDrive.ps1 -VhdPath 'C:\DevDrive\DevDrive.vhdx' -DriveLetter X -SizeGB 50 -VolumeLabel 'Dev Drive'
#>
# ------------------------------------------------------------
# Configuration - edit these defaults or pass parameters
# ------------------------------------------------------------
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^[A-Za-z]:\\[^"\r\n]*\.vhdx$')]
    [Alias('Path')]
    [string] $VhdPath = 'C:\DevDrive\DevDrive.vhdx',

    [ValidatePattern('^[D-Zd-z]$')]
    [string] $DriveLetter = 'X',

    [ValidateRange(50, 65535)]
    [int] $SizeGB = 50,

    [ValidateNotNullOrEmpty()]
    [ValidateLength(1, 32)]
    [Alias('Name')]
    [string] $VolumeLabel = 'Dev Drive'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Reused before mounting and immediately before assigning the letter.
function Assert-LetterAvailable {
    param($ExpectedPartition = $null)

    $partitions = @(Get-Partition | Where-Object { $_.DriveLetter -eq $DriveLetter })
    if ($partitions.Count -gt 0) {
        if ($null -ne $ExpectedPartition -and $partitions.Count -eq 1 -and
            $partitions[0].DiskNumber -eq $ExpectedPartition.DiskNumber -and
            $partitions[0].PartitionNumber -eq $ExpectedPartition.PartitionNumber) {
            return
        }
        throw "${DriveLetter}: is already assigned to another partition. Nothing will be overwritten."
    }

    # Include optical/removable volumes, mapped network drives, and SUBST/PS drives.
    $volumes = @(Get-Volume | Where-Object { $_.DriveLetter -eq $DriveLetter })
    $logicalDisks = @(Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DeviceID -eq "${DriveLetter}:" })
    $psDrives = @(Get-PSDrive | Where-Object { $_.Name -eq $DriveLetter })
    if ($volumes.Count -or $logicalDisks.Count -or $psDrives.Count -or
        (Test-Path -LiteralPath "${DriveLetter}:\")) {
        throw "${DriveLetter}: is already in use. Choose a different drive letter."
    }
}

try {
    Write-Host 'Setting up Dev Drive...'

    # ------------------------------------------------------------
    # 1. Check Windows and PowerShell requirements
    # ------------------------------------------------------------
    Write-Host 'Checking Windows and PowerShell requirements...'
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) {
        throw 'Run this script in 64-bit PowerShell on Windows 11 as Administrator.'
    }
    $WindowsVersion = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $WindowsBuild = [int] $WindowsVersion.CurrentBuildNumber
    if ($WindowsBuild -lt 22621 -or ($WindowsBuild -eq 22621 -and [int] $WindowsVersion.UBR -lt 2338)) {
        throw 'Dev Drive requires Windows 11 build 22621.2338 or later.'
    }
    Import-Module Storage -ErrorAction Stop
    if (-not (Get-Command Format-Volume).Parameters.ContainsKey('DevDrive')) {
        throw 'The installed Storage module does not support Format-Volume -DevDrive.'
    }
    $DriveLetter = $DriveLetter.ToUpperInvariant()
    $VhdPath = [IO.Path]::GetFullPath($VhdPath)

    # ------------------------------------------------------------
    # 2. Check the VHDX and requested drive letter
    # ------------------------------------------------------------
    Write-Host "Checking '$VhdPath' and ${DriveLetter}:..."
    $VhdExists = Test-Path -LiteralPath $VhdPath
    $Partition = $null
    $Disk = $null

    if ($VhdExists) {
        if (-not (Test-Path -LiteralPath $VhdPath -PathType Leaf)) {
            throw "The VHDX path is not a file: $VhdPath"
        }
        $DiskImage = Get-DiskImage -ImagePath $VhdPath
        if ($DiskImage.Attached) {
            $Disk = $DiskImage | Get-Disk
            $DataPartitions = @(Get-Partition -DiskNumber $Disk.Number | Where-Object { $_.Type -ne 'Reserved' })
            if ($DataPartitions.Count -ne 1) {
                throw 'The existing VHDX must have exactly one data partition. No formatting was attempted.'
            }
            $Partition = $DataPartitions[0]
        }
    }
    Assert-LetterAvailable -ExpectedPartition $Partition

    # ------------------------------------------------------------
    # 3. Check free space for a new VHDX
    # ------------------------------------------------------------
    if (-not $VhdExists) {
        # DiskPart's command file uses ASCII; reject paths that would be corrupted.
        if ($VhdPath -match '[^\x20-\x7E]') {
            throw 'Creating a VHDX requires a path containing only printable ASCII characters.'
        }
        # SizeGB is the data partition size. Reserve extra virtual disk space for GPT.
        $PartitionSizeBytes = [uint64] $SizeGB * 1GB
        $VhdSizeBytes = $PartitionSizeBytes + 256MB
        $BackingVolume = Get-Volume -FilePath ([IO.Path]::GetPathRoot($VhdPath))
        if ($BackingVolume.SizeRemaining -lt ($VhdSizeBytes + 256MB)) {
            throw "The backing volume needs at least $SizeGB GB plus 512 MB of free space."
        }
    }

    # One approval boundary also makes -WhatIf skip all disk changes.
    $Action = if ($VhdExists) { "Mount existing VHDX at ${DriveLetter}: without formatting" } else {
        "Create a dynamic VHDX with a $SizeGB GB data partition and format it as '$VolumeLabel' at ${DriveLetter}:"
    }
    if (-not $PSCmdlet.ShouldProcess($VhdPath, $Action)) { return }

    # ------------------------------------------------------------
    # 4. Create the VHDX folder if needed
    # ------------------------------------------------------------
    if (-not $VhdExists) {
        $VhdFolder = Split-Path -Parent $VhdPath
        if (-not (Test-Path -LiteralPath $VhdFolder -PathType Container)) {
            Write-Host "Creating folder: $VhdFolder"
            New-Item -ItemType Directory -Path $VhdFolder | Out-Null
        }
    }

    # ------------------------------------------------------------
    # 5. Create a dynamic VHDX, or reuse the existing file
    # ------------------------------------------------------------
    if (-not $VhdExists) {
        Write-Host "Creating dynamic VHDX for a $SizeGB GB partition (plus 256 MB disk overhead): $VhdPath"
        # DiskPart is built into Windows; no Hyper-V module or nested virtualization needed.
        $DiskPartScript = [IO.Path]::GetTempFileName()
        try {
            $SizeMB = [uint64] ($VhdSizeBytes / 1MB)
            # DiskPart rejects the UTF-16 command file produced by -Encoding Unicode.
            $DiskPartCommands = "create vdisk file=`"$VhdPath`" maximum=$SizeMB type=expandable`r`nexit`r`n"
            $DiskPartCommands | Set-Content -LiteralPath $DiskPartScript -Encoding ASCII -NoNewline
            $DiskPartOutput = & "$env:SystemRoot\System32\diskpart.exe" /s $DiskPartScript 2>&1
            $DiskPartExitCode = $LASTEXITCODE
            Write-Verbose ($DiskPartOutput -join [Environment]::NewLine)
            if ($DiskPartExitCode -ne 0 -or -not (Test-Path -LiteralPath $VhdPath -PathType Leaf)) {
                throw "VHDX creation failed (DiskPart exit $DiskPartExitCode): $($DiskPartOutput -join ' ')"
            }
        }
        finally {
            Remove-Item -LiteralPath $DiskPartScript -Force
        }
    }
    else {
        Write-Host "Reusing existing VHDX: $VhdPath"
    }

    # ------------------------------------------------------------
    # 6. Mount the VHDX and identify its disk
    # ------------------------------------------------------------
    $DiskImage = Get-DiskImage -ImagePath $VhdPath
    if (-not $DiskImage.Attached) {
        Write-Host 'Mounting VHDX...'
        Mount-DiskImage -ImagePath $VhdPath -NoDriveLetter -Access ReadWrite -ErrorAction Stop | Out-Null
    }
    else {
        Write-Host 'VHDX is already mounted.'
    }
    $Disk = Get-DiskImage -ImagePath $VhdPath | Get-Disk
    if ($Disk.IsBoot -or $Disk.IsSystem -or $Disk.IsReadOnly -or $Disk.IsOffline) {
        throw 'The VHDX disk is a system/boot disk, read-only, or offline. Stopping without changing disk flags.'
    }

    # ------------------------------------------------------------
    # 7. Initialize only a newly created disk
    # ------------------------------------------------------------
    if (-not $VhdExists) {
        if ($Disk.PartitionStyle -ne 'RAW') {
            throw 'The new VHDX is not blank. Refusing to initialize or format it.'
        }
        Write-Host 'Initializing new disk as GPT...'
        Initialize-Disk -Number $Disk.Number -PartitionStyle GPT -ErrorAction Stop | Out-Null
    }

    # ------------------------------------------------------------
    # 8. Create a new partition, or inspect the existing partition
    # ------------------------------------------------------------
    if (-not $VhdExists) {
        Write-Host 'Creating data partition...'
        $Partition = New-Partition -DiskNumber $Disk.Number -Size $PartitionSizeBytes -ErrorAction Stop
    }
    else {
        Write-Host 'Inspecting existing data partition (no formatting)...'
        $DataPartitions = @(Get-Partition -DiskNumber $Disk.Number | Where-Object { $_.Type -ne 'Reserved' })
        if ($DataPartitions.Count -ne 1) {
            throw 'The existing VHDX must have exactly one data partition. It has not been formatted.'
        }
        $Partition = $DataPartitions[0]
        $Volume = $Partition | Get-Volume
        if ($Volume.FileSystem -ne 'ReFS') {
            throw 'The existing volume is not ReFS. It has been attached but will not be reformatted or assigned the requested letter.'
        }
    }

    # ------------------------------------------------------------
    # 9. Format only the new partition as a Dev Drive
    # ------------------------------------------------------------
    if (-not $VhdExists) {
        Write-Host "Formatting new partition as Dev Drive: $VolumeLabel"
        if ($Partition.Size -lt 50GB) {
            throw 'The new data partition is below the 50 GB minimum. Stopping before formatting.'
        }
        # Target the partition object, never a drive letter that could belong to another disk.
        $Volume = Format-Volume `
            -Partition $Partition `
            -DevDrive `
            -FileSystem ReFS `
            -NewFileSystemLabel $VolumeLabel `
            -Confirm:$false `
            -ErrorAction Stop
        if ($null -eq $Volume -or $Volume.FileSystem -ne 'ReFS') {
            throw 'Formatting did not return a ReFS volume. Stopping before drive-letter assignment.'
        }
    }
    else {
        Write-Host 'Keeping the existing filesystem and label.'
    }

    # ------------------------------------------------------------
    # 10. Assign the requested drive letter
    # ------------------------------------------------------------
    # Recheck immediately before assignment, including after a potentially lengthy format.
    Assert-LetterAvailable -ExpectedPartition $Partition
    if ($Partition.DriveLetter -ne $DriveLetter) {
        Write-Host "Assigning drive letter ${DriveLetter}:..."
        Set-Partition `
            -DiskNumber $Disk.Number `
            -PartitionNumber $Partition.PartitionNumber `
            -NewDriveLetter $DriveLetter `
            -ErrorAction Stop
    }
    else {
        Write-Host "Drive ${DriveLetter}: already belongs to this VHDX."
    }

    # ------------------------------------------------------------
    # 11. Verify the resulting drive and display its configuration
    # ------------------------------------------------------------
    Write-Host "Verifying ${DriveLetter}:..."
    $MountedPartition = Get-Partition -DiskNumber $Disk.Number -PartitionNumber $Partition.PartitionNumber
    $Volume = $MountedPartition | Get-Volume
    if ($MountedPartition.DriveLetter -ne $DriveLetter -or $Volume.FileSystem -ne 'ReFS') {
        throw 'The resulting drive letter or filesystem did not match the expected configuration.'
    }
    # Print Windows' Dev Drive status without relying on localized output text.
    & "$env:SystemRoot\System32\fsutil.exe" devdrv query "${DriveLetter}:" | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw 'Windows could not confirm Dev Drive status. The VHDX remains attached; it was not reformatted if it already existed.'
    }
    Write-Host "Dev Drive setup completed at ${DriveLetter}:"
    [pscustomobject]@{
        Path = $VhdPath
        Drive = "${DriveLetter}:"
        Name = $Volume.FileSystemLabel
        VirtualDiskSizeGB = [math]::Round($Disk.Size / 1GB, 2)
        ReusedExistingVhdx = $VhdExists
    }
}
catch {
    Write-Error "Dev Drive setup failed: $($_.Exception.Message) Any VHDX created or attached by this run is retained for inspection." -ErrorAction Continue
    exit 1
}
