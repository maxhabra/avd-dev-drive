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
    if ($VhdSizeBytes -ne ($SizeGB * 1GB) -or $SizeMB -ne ($SizeGB * 1024)) {
        throw 'VHDX must match the configured size with no extra capacity.'
    }
    . ([scriptblock]::Create($commandAssignment.Extent.Text))
    . ([scriptblock]::Create($commandWrite.Extent.Text))
    $actualBytes = [IO.File]::ReadAllBytes($DiskPartScript)
    $expectedText = "create vdisk file=`"C:\Dev Drive\DevDrive.vhdx`" maximum=$SizeMB type=expandable`r`nexit`r`n"
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

# Execute the actual assignment/format sequence with fake Storage cmdlets.
$scriptText = [IO.File]::ReadAllText($source)
$sequenceStart = $scriptText.IndexOf('    # 9. Assign and verify')
$sequenceEnd = $scriptText.IndexOf('    # 11. Verify', $sequenceStart)
if ($sequenceStart -lt 0 -or $sequenceEnd -lt 0) { throw 'Cannot locate assignment/format sequence.' }
$sequence = [scriptblock]::Create($scriptText.Substring($sequenceStart, $sequenceEnd - $sequenceStart))
function Get-Partition {
    [CmdletBinding()]
    param($DriveLetter)
    if ($PSBoundParameters.ContainsKey('DriveLetter')) {
        $script:events.Add('Verify')
        if ($script:scenario -eq 'WrongDisk') {
            return [pscustomobject]@{ DiskNumber = 99; PartitionNumber = 2; DriveLetter = 'X' }
        }
        if ($script:scenario -eq 'WrongPartition') {
            return [pscustomobject]@{ DiskNumber = 3; PartitionNumber = 99; DriveLetter = 'X' }
        }
        if ($script:scenario -eq 'MissingAssignment') { return }
        if ($script:target.DriveLetter -eq $DriveLetter) { $script:target }
        return
    }
    if ($script:scenario -eq 'Collision') {
        return [pscustomobject]@{ DiskNumber = 99; PartitionNumber = 2; DriveLetter = 'X' }
    }
    $script:target
}
function Set-Partition {
    [CmdletBinding()]
    param($DiskNumber, $PartitionNumber, $NewDriveLetter)
    $script:events.Add('Assign')
    if ($script:scenario -eq 'AssignmentError') { Write-Error 'Assignment failed'; return }
    if ($DiskNumber -ne 3 -or $PartitionNumber -ne 2 -or $NewDriveLetter -ne 'X') {
        throw 'Wrong partition selected for assignment.'
    }
    $script:target.DriveLetter = $NewDriveLetter
}
function Invoke-TestFormat {
    if (($script:events -join ',') -notmatch 'Verify$' -or $script:target.DriveLetter -ne 'X') {
        throw 'Format ran before assignment and verification.'
    }
    if (($args -join ' ') -ne 'X: /FS:ReFS /DevDrv /Q /V:DevDrive /Y') {
        throw 'Wrong native format arguments.'
    }
    $script:events.Add('Format')
    $global:LASTEXITCODE = if ($script:scenario -eq 'FormatError') { 4 } else { 0 }
}
function Get-Volume {
    [CmdletBinding()]
    param($DriveLetter)
    if (-not $PSBoundParameters.ContainsKey('DriveLetter')) { return }
    switch ($script:scenario) {
        'EmptyFormat' { return }
        'WrongFilesystem' { [pscustomobject]@{ FileSystem = 'NTFS' } }
        default { [pscustomobject]@{ FileSystem = 'ReFS' } }
    }
}
function Set-Volume {
    [CmdletBinding()]
    param($DriveLetter, $NewFileSystemLabel)
    if ($DriveLetter -ne 'X' -or $NewFileSystemLabel -ne 'Dev Drive') { throw 'Incorrect label arguments.' }
    $script:events.Add('Label')
}
$FormatCommand = 'Invoke-TestFormat'
$script:volumes = @()
$script:logical = @()
$script:drives = @()
$script:pathExists = $false
foreach ($case in @('Success', 'Existing', 'Collision', 'AssignmentError', 'WrongDisk', 'WrongPartition', 'MissingAssignment', 'FormatError', 'EmptyFormat', 'WrongFilesystem')) {
    $script:scenario = $case
    $script:events = [System.Collections.Generic.List[string]]::new()
    $script:target = [pscustomobject]@{ DiskNumber = 3; PartitionNumber = 2; DriveLetter = ''; Size = $SizeGB * 1GB - 17MB }
    if ($case -eq 'Existing') { $script:target.DriveLetter = 'X' }
    $Disk = [pscustomobject]@{ Number = 3 }
    $Partition = $script:target
    $VhdExists = $case -eq 'Existing'
    $DriveLetter = 'X'
    $VolumeLabel = 'Dev Drive'
    $caught = $null
    $ErrorActionPreference = 'Continue'
    try { & $sequence } catch { $caught = $_ }
    $ErrorActionPreference = 'Stop'
    if ($case -in @('Success', 'Existing')) {
        if ($null -ne $caught) { throw $caught }
        $expectedEvents = if ($case -eq 'Success') { 'Assign,Verify,Format,Label' } else { 'Verify' }
        if (($script:events -join ',') -ne $expectedEvents) { throw "Incorrect order for $case" }
    }
    else {
        if ($null -eq $caught) { throw "Expected failure for $case" }
        if ($script:events.Contains('Label')) { throw "Label applied despite failure for $case" }
        if ($case -notin @('FormatError', 'EmptyFormat', 'WrongFilesystem') -and $script:events.Contains('Format')) {
            throw "Unsafe formatting occurred for $case"
        }
    }
}
Write-Host 'PASS: 10 assignment/format scenarios, including exact target checks, label spaces, reuse, and errors.'
