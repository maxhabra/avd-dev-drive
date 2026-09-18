#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Collects Dev Drive diagnostics without creating, mounting, formatting, or modifying disks.
.DESCRIPTION
Run in the same PowerShell window as the failed provisioning attempt to include
the original error records. Reports the installed formatter implementation so
the ByPartition path can be inspected without another formatting attempt.
#>
[CmdletBinding()]
param([string] $VhdPath = 'C:\DevDrive\DevDrive.vhdx')

# Capture existing errors before diagnostic commands add any of their own.
$PreviousErrors = @($Error | Select-Object -First 5)
$ErrorActionPreference = 'Stop'

Write-Output '=== Original errors from this PowerShell session ==='
foreach ($Record in $PreviousErrors) {
    $Record | Format-List FullyQualifiedErrorId, CategoryInfo, ErrorDetails, ScriptStackTrace
    $Record.InvocationInfo | Format-List PositionMessage
    $Record.Exception | Format-List * -Force
}

Write-Output '=== Windows build and PowerShell ==='
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' |
    Select-Object ProductName, EditionID, DisplayVersion, CurrentBuildNumber, UBR |
    Format-List
$PSVersionTable | Format-Table -AutoSize

Write-Output '=== Dev Drive enablement ==='
& "$env:SystemRoot\System32\fsutil.exe" devdrv query

Write-Output '=== VHDX disk, partition, and volume ==='
try {
    $Image = Get-DiskImage -ImagePath $VhdPath
    $Image | Format-List ImagePath, Attached, Size, StorageType
    if ($Image.Attached) {
        $Disk = $Image | Get-Disk
        $Disk | Format-List Number, BusType, PartitionStyle, Size, LogicalSectorSize, PhysicalSectorSize, IsOffline, IsReadOnly, IsBoot, IsSystem
        $Partitions = @($Disk | Get-Partition)
        $Partitions | Format-List DiskNumber, PartitionNumber, Type, GptType, Size, DriveLetter, AccessPaths, IsReadOnly, IsOffline
        $Partitions | Where-Object Type -eq 'Basic' | Get-Volume |
            Format-List UniqueId, Path, FileSystem, FileSystemLabel, DriveType, HealthStatus, OperationalStatus, Size
    }
}
catch { Write-Warning $_.Exception.Message }

Write-Output '=== Installed Format-Volume command ==='
$Formatter = Get-Command Format-Volume
$Formatter | Format-List Name, CommandType, Source, Version, ModuleName
Write-Output '=== Formatter source (check how ByPartition forwards DevDrive) ==='
$Formatter.Definition
