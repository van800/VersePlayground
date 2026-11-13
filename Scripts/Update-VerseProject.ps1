# Copyright (c) 2026 JetBrains

<#
.SYNOPSIS
Writes Intermediate/vproject/VersePlayground.vproject, the Verse project that VersePlayground-Verse.code-workspace
uses.

.DESCRIPTION
Setup.bat runs this script after it builds verse.exe. Run it again after adding or removing a folder of .verse files
under Samples/.

The project is built the same way as the one the VS Code extension gives the language server
(buildWorkspaceProject in Extension/src/verse-project.ts): the engine packages of VNI.vproject, which UnrealBuildTool
writes while it builds verse.exe, become read-only, and each folder of .verse files under Samples/ becomes its own
package under /user@localhost, the Verse path that verse.exe gives the script it runs.

IDEs that open VersePlayground-Verse.code-workspace, such as Rider, read the project from the vproject folder of the
workspace. verse.exe does not read it.

.PARAMETER EngineDir
Root of the engine checkout, the folder that contains Engine/. Defaults to engineDir in VersePlayground.local.json,
which Setup.bat writes.

.EXAMPLE
.\Scripts\Update-VerseProject.ps1
#>
[CmdletBinding()]
param(
    [string] $EngineDir
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$SamplesDir = Join-Path $RepoRoot 'Samples'
$IntermediateDir = Join-Path $RepoRoot 'Intermediate'
$ProjectDir = Join-Path $IntermediateDir 'vproject'
# The workspace is VersePlayground-Verse.code-workspace, and IDEs look for <workspace name without -Verse>.vproject.
$ProjectFile = Join-Path $ProjectDir 'VersePlayground.vproject'
$VniOutputDir = Join-Path $IntermediateDir 'vni'
$LocalStateFile = Join-Path $RepoRoot 'VersePlayground.local.json'

# Same as EXCLUDED_ENGINE_PACKAGES in Extension/src/verse-project.ts, so that every tool sees the same packages.
$ExcludedEnginePackages = @(
    'VerseSpatialMath/VerseSpatialMath',
    'EpicGamesEngineRestricted/EpicGamesEngineRestricted',
    'VerseSimulationMetadata/VerseSimulationMetadata'
)
$UserVersePath = '/user@localhost'
$UserPackagePrefix = 'VersePlayground'

# Windows PowerShell 5.1 writes arrays held in note properties as {"value": [...], "Count": n} while this type data
# exists. Removing it lasts only for this session.
if ($PSVersionTable.PSVersion.Major -lt 6) {
    Remove-TypeData -TypeName System.Array -ErrorAction SilentlyContinue
}

function Set-JsonProperty {
    param([object] $Object, [string] $Name, [object] $Value)

    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

if (-not $EngineDir) {
    if (-not (Test-Path -LiteralPath $LocalStateFile)) {
        throw "$LocalStateFile does not exist. Run Setup.bat first, or pass -EngineDir."
    }
    $localState = Get-Content -LiteralPath $LocalStateFile -Raw | ConvertFrom-Json
    if (-not $localState.PSObject.Properties['engineDir'] -or -not $localState.engineDir) {
        throw "$LocalStateFile has no engineDir. Run Setup.bat again, or pass -EngineDir."
    }
    $EngineDir = $localState.engineDir
}
$EngineDir = [System.IO.Path]::GetFullPath($EngineDir)

$vniProjectPath = Join-Path $EngineDir 'Engine\Intermediate\Build\Win64\verse\VNI.vproject'
if (-not (Test-Path -LiteralPath $vniProjectPath)) {
    throw "$vniProjectPath does not exist. The verse.exe build creates it, so run Setup.bat again."
}

$project = Get-Content -LiteralPath $vniProjectPath -Raw | ConvertFrom-Json
if (-not $project.PSObject.Properties['packages']) {
    throw "$vniProjectPath has no `"packages`" array."
}

$enginePackages = @($project.packages | Where-Object { $ExcludedEnginePackages -notcontains $_.desc.name })
foreach ($enginePackage in $enginePackages) {
    $settings = $enginePackage.desc.settings
    $dependencies = @()
    if ($settings.PSObject.Properties['dependencyPackages']) {
        $dependencies = @($settings.dependencyPackages | Where-Object { $ExcludedEnginePackages -notcontains $_ })
    }
    Set-JsonProperty $settings 'dependencyPackages' $dependencies
    # Without VNI the engine's .native.verse files are rejected with "Native attributes are not allowed".
    Set-JsonProperty $settings 'enableVNI' $true
    Set-JsonProperty $settings 'vniDestDir' $VniOutputDir
    Set-JsonProperty $enginePackage 'readOnly' $true
}
$enginePackageNames = @($enginePackages | ForEach-Object { $_.desc.name })

# One package per folder, because two Main functions in one package are ambiguous (V3532). Sorted so that the
# package numbers do not change between runs.
$userFolders = @(Get-ChildItem -LiteralPath $SamplesDir -Recurse -File -Filter '*.verse' |
    ForEach-Object { $_.DirectoryName } |
    Sort-Object -Unique)
$userPackages = @()
for ($folderIndex = 0; $folderIndex -lt $userFolders.Count; $folderIndex++) {
    $userPackages += [pscustomobject] [ordered] @{
        desc = [pscustomobject] [ordered] @{
            name = "$UserPackagePrefix/$folderIndex"
            publicName = ''
            dirPath = $userFolders[$folderIndex]
            settings = [pscustomobject] [ordered] @{
                versePath = $UserVersePath
                verseScope = 'PublicUser'
                role = 'Source'
                dependencyPackages = $enginePackageNames
                allowExperimental = $true
            }
        }
        readOnly = $false
    }
}

Set-JsonProperty $project 'packages' (@($userPackages) + @($enginePackages))

New-Item -ItemType Directory -Path $ProjectDir -Force | Out-Null
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($ProjectFile, ($project | ConvertTo-Json -Depth 100) + "`n", $utf8NoBom)
Write-Host "Wrote $ProjectFile with $($userFolders.Count) sample folder(s) and $($enginePackages.Count) engine package(s)."
