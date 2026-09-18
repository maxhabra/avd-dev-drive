# Non-destructive checks; does not execute the provisioning script or use real disks.
$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'New-DevDrive.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref] $tokens, [ref] $parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }

# Execute the actual command-file generation statements, without launching DiskPart.
$commandAssignment = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -eq '$DiskPartCommands'
}, $true)
$commandWrite = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.PipelineAst] -and
    $node.Extent.Text -like '$DiskPartCommands | Set-Content*'
}, $true)
if ($null -eq $commandAssignment -or $null -eq $commandWrite) {
    throw 'Cannot locate DiskPart command-file generation statements.'
}
$DiskPartScript = [IO.Path]::GetTempFileName()
try {
    $VhdPath = 'C:\Dev Drive\DevDrive.vhdx'
    $sizeParameter = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'SizeGB' }
    $SizeGB = $sizeParameter.DefaultValue.SafeGetValue()
    foreach ($variableName in @('$VhdSizeBytes', '$SizeMB')) {
        $assignment = $ast.Find({ param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq $variableName
        }, $true)
        . ([scriptblock]::Create($assignment.Extent.Text))
    }
    if ($SizeGB -ne 52 -or $VhdSizeBytes -ne 52GB -or $SizeMB -ne 53248) {
        throw 'Default VHDX must be exactly 52 GiB (53248 MiB), with no extra capacity.'
    }
    . ([scriptblock]::Create($commandAssignment.Extent.Text))
    . ([scriptblock]::Create($commandWrite.Extent.Text))
    $actualBytes = [IO.File]::ReadAllBytes($DiskPartScript)
    $expectedText = "create vdisk file=`"C:\Dev Drive\DevDrive.vhdx`" maximum=53248 type=expandable`r`nexit`r`n"
    $expectedBytes = [Text.Encoding]::ASCII.GetBytes($expectedText)
    if ([Convert]::ToBase64String($actualBytes) -ne [Convert]::ToBase64String($expectedBytes)) {
        throw 'DiskPart file must contain the quoted path, ASCII without a BOM, and CRLF line endings.'
    }
}
finally {
    Remove-Item -LiteralPath $DiskPartScript -Force
}
Write-Host 'PASS: DiskPart command-file bytes, quoted path, and Windows line endings.'

$functionAst = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-LetterAvailable'
}, $true)
. ([scriptblock]::Create($functionAst.Extent.Text))

$DriveLetter = 'X'
$script:parts = @()
$script:volumes = @()
$script:logical = @()
$script:drives = @()
$script:pathExists = $false
function Get-Partition { $script:parts }
function Get-Volume { $script:volumes }
function Get-CimInstance { param($ClassName) $script:logical }
function Get-PSDrive { $script:drives }
function Test-Path { param($LiteralPath) $script:pathExists }
function Expect-Blocked {
    param([scriptblock] $Action)
    $blocked = $false
    try { & $Action } catch { $blocked = $true }
    if (-not $blocked) { throw 'Expected occupied-letter check to block.' }
}

Assert-LetterAvailable
$own = [pscustomobject]@{ DriveLetter = 'X'; DiskNumber = 3; PartitionNumber = 2 }
$script:parts = @($own)
Assert-LetterAvailable -ExpectedPartition $own
Expect-Blocked { Assert-LetterAvailable }
Expect-Blocked { Assert-LetterAvailable -ExpectedPartition ([pscustomobject]@{ DiskNumber = 4; PartitionNumber = 2 }) }
Expect-Blocked { Assert-LetterAvailable -ExpectedPartition ([pscustomobject]@{ DiskNumber = 3; PartitionNumber = 1 }) }
$script:parts = @()
$script:volumes = @([pscustomobject]@{ DriveLetter = 'X' })
Expect-Blocked { Assert-LetterAvailable }
$script:volumes = @()
$script:logical = @([pscustomobject]@{ DeviceID = 'X:' })
Expect-Blocked { Assert-LetterAvailable }
$script:logical = @()
$script:drives = @([pscustomobject]@{ Name = 'X' })
Expect-Blocked { Assert-LetterAvailable }
$script:drives = @()
$script:pathExists = $true
Expect-Blocked { Assert-LetterAvailable }
$script:pathExists = $false
$script:parts = @([pscustomobject]@{ DriveLetter = 'Y'; DiskNumber = 4; PartitionNumber = 1 })
Assert-LetterAvailable
Write-Host 'PASS: PowerShell syntax and 10 drive-letter safety scenarios.'

# Exercise the actual formatting branch. A provider error or empty result must
# prevent execution from reaching the subsequent drive-letter assignment step.
$formatBranch = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
    $node.Extent.Text -like '*$Volume = Format-Volume*'
}, $true)
if ($null -eq $formatBranch) { throw 'Cannot locate formatting branch.' }
$formatBlock = [scriptblock]::Create($formatBranch.Extent.Text)
$VhdExists = $false
$Partition = [pscustomobject]@{ DiskNumber = 3; PartitionNumber = 2; Size = 50GB }
$VolumeLabel = 'Dev Drive'
function Format-Volume {
    [CmdletBinding(SupportsShouldProcess)]
    param($Partition, [switch] $DevDrive, $FileSystem, $NewFileSystemLabel)
    switch ($script:formatScenario) {
        'Error' { Write-Error 'Not Supported' }
        'Empty' { return }
        'WrongFilesystem' { [pscustomobject]@{ FileSystem = 'NTFS' } }
        'Success' { [pscustomobject]@{ FileSystem = 'ReFS' } }
    }
}
# Ensure the explicit -ErrorAction Stop works even with a Continue preference.
$ErrorActionPreference = 'Continue'
foreach ($scenario in @('Error', 'Empty', 'WrongFilesystem')) {
    $script:formatScenario = $scenario
    $reachedAssignment = $false
    $caughtFailure = $false
    try {
        & $formatBlock
        $reachedAssignment = $true
    }
    catch { $caughtFailure = $true }
    if (-not $caughtFailure -or $reachedAssignment) {
        throw "Formatting scenario '$scenario' did not stop before assignment."
    }
}
$ErrorActionPreference = 'Stop'
$script:formatScenario = 'Success'
& $formatBlock
Write-Host 'PASS: format errors, missing output, and non-ReFS output stop; ReFS success proceeds.'

$Partition.Size = 50GB - 17MB
$blockedUndersizedPartition = $false
try { & $formatBlock } catch { $blockedUndersizedPartition = $true }
if (-not $blockedUndersizedPartition) { throw 'An undersized partition must be rejected before formatting.' }
Write-Host 'PASS: minimum partition size and exact 52 GiB VHDX capacity.'
