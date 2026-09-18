# Non-destructive checks; does not execute the provisioning script or use real disks.
$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'New-DevDrive.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref] $tokens, [ref] $parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
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
