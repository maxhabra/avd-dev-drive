#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Creates a Dev Drive or mounts the existing VHDX without formatting it.
.EXAMPLE
.\New-DevDrive.ps1
.EXAMPLE
.\New-DevDrive.ps1 -Path 'C:\DevDrive\DevDrive.vhdx' -DriveLetter X -SizeGB 50 -Name 'Dev Drive'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^[A-Za-z]:\\[^"\r\n]*\.vhdx$')]
    [string] $Path = 'C:\DevDrive\DevDrive.vhdx',

    [ValidatePattern('^[D-Zd-z]$')]
    [string] $DriveLetter = 'X',

    [ValidateRange(50, 65535)]
    [int] $SizeGB = 50,

    [ValidateNotNullOrEmpty()]
    [ValidateLength(1, 32)]
    [string] $Name = 'Dev Drive'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) {
        throw 'Run this script in 64-bit PowerShell on Windows 11 as Administrator.'
    }
    $version = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int] $version.CurrentBuildNumber
    if ($build -lt 22621 -or ($build -eq 22621 -and [int] $version.UBR -lt 2338)) {
        throw 'Dev Drive requires Windows 11 build 22621.2338 or later.'
    }
    Import-Module Storage -ErrorAction Stop
    if (-not (Get-Command Format-Volume).Parameters.ContainsKey('DevDrive')) {
        throw 'The installed Storage module does not support Format-Volume -DevDrive.'
    }
    $DriveLetter = $DriveLetter.ToUpperInvariant()
    $Path = [IO.Path]::GetFullPath($Path)
    $exists = Test-Path -LiteralPath $Path
    $partition = $null
    $disk = $null

    if ($exists) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "The VHDX path is not a file: $Path"
        }
        $image = Get-DiskImage -ImagePath $Path
        if ($image.Attached) {
            $disk = $image | Get-Disk
            $candidates = @(Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Type -ne 'Reserved' })
            if ($candidates.Count -ne 1) {
                throw 'The existing VHDX must have exactly one data partition. No formatting was attempted.'
            }
            $partition = $candidates[0]
        }
    }
    Assert-LetterAvailable -ExpectedPartition $partition

    if (-not $exists) {
        # Keep the requested VHDX capacity exact. Its usable volume is slightly smaller.
        $sizeBytes = [uint64] $SizeGB * 1GB
        $hostVolume = Get-Volume -FilePath ([IO.Path]::GetPathRoot($Path))
        if ($hostVolume.SizeRemaining -lt ($sizeBytes + 256MB)) {
            throw "The backing volume needs at least $SizeGB GB plus 256 MB of free space."
        }
    }

    $action = if ($exists) { "Mount existing VHDX at ${DriveLetter}: without formatting" } else {
        "Create a $SizeGB GB dynamic VHDX and format its new volume as '$Name' at ${DriveLetter}:"
    }
    if (-not $PSCmdlet.ShouldProcess($Path, $action)) { return }

    if (-not $exists) {
        $parent = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent | Out-Null
        }
        # DiskPart is built into Windows; no Hyper-V module or nested virtualization needed.
        $diskPartFile = [IO.Path]::GetTempFileName()
        try {
            $maximumMB = [uint64] $SizeGB * 1024
            @("create vdisk file=`"$Path`" maximum=$maximumMB type=expandable", 'exit') |
                Set-Content -LiteralPath $diskPartFile -Encoding Unicode
            $output = & "$env:SystemRoot\System32\diskpart.exe" /s $diskPartFile 2>&1
            $code = $LASTEXITCODE
            Write-Verbose ($output -join [Environment]::NewLine)
            if ($code -ne 0 -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
                throw "VHDX creation failed (DiskPart exit $code): $($output -join ' ')"
            }
        }
        finally {
            Remove-Item -LiteralPath $diskPartFile -Force
        }
    }

    $image = Get-DiskImage -ImagePath $Path
    if (-not $image.Attached) {
        Mount-DiskImage -ImagePath $Path -NoDriveLetter -Access ReadWrite | Out-Null
    }
    $disk = Get-DiskImage -ImagePath $Path | Get-Disk
    if ($disk.IsBoot -or $disk.IsSystem -or $disk.IsReadOnly -or $disk.IsOffline) {
        throw 'The VHDX disk is a system/boot disk, read-only, or offline. Stopping without changing disk flags.'
    }

    if (-not $exists) {
        if ($disk.PartitionStyle -ne 'RAW') {
            throw 'The new VHDX is not blank. Refusing to initialize or format it.'
        }
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null
        $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize
        # Target the partition object, never a drive letter that could belong to another disk.
        $volume = Format-Volume -Partition $partition -DevDrive -FileSystem ReFS -NewFileSystemLabel $Name -Confirm:$false
    }
    else {
        $candidates = @(Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Type -ne 'Reserved' })
        if ($candidates.Count -ne 1) {
            throw 'The existing VHDX must have exactly one data partition. It has not been formatted.'
        }
        $partition = $candidates[0]
        $volume = $partition | Get-Volume
        if ($volume.FileSystem -ne 'ReFS') {
            throw 'The existing volume is not ReFS. It has been attached but will not be reformatted or assigned the requested letter.'
        }
    }

    # Recheck immediately before assignment, including after a potentially lengthy format.
    Assert-LetterAvailable -ExpectedPartition $partition
    if ($partition.DriveLetter -ne $DriveLetter) {
        Set-Partition -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -NewDriveLetter $DriveLetter
    }
    $actual = Get-Partition -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber
    $volume = $actual | Get-Volume
    if ($actual.DriveLetter -ne $DriveLetter -or $volume.FileSystem -ne 'ReFS') {
        throw 'The resulting drive letter or filesystem did not match the expected configuration.'
    }
    # Print Windows' Dev Drive status without relying on localized output text.
    & "$env:SystemRoot\System32\fsutil.exe" devdrv query "${DriveLetter}:" | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw 'Windows could not confirm Dev Drive status. The VHDX remains attached; it was not reformatted if it already existed.'
    }
    [pscustomobject]@{
        Path = $Path
        Drive = "${DriveLetter}:"
        Name = $volume.FileSystemLabel
        VirtualDiskSizeGB = [math]::Round($disk.Size / 1GB, 2)
        ReusedExistingVhdx = $exists
    }
}
catch {
    Write-Error "Dev Drive setup failed: $($_.Exception.Message) Any VHDX created or attached by this run is retained for inspection." -ErrorAction Continue
    exit 1
}
