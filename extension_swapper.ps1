[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$SourceRoot = 'C:\dev\gzdoda\build\gzdoda_14.14.2\archives\github.reference\doda-core-unpacked',

    [Parameter(Mandatory=$false)]
    [string]$StagingRoot = 'C:\dev\gzdoda\build\gzdoda_14.14.2\archives\github.reference\doda-core-unpacked',

    [string[]]$ExcludeDirs = @(
        '.git',
        '.vs',
        'bin',
        'obj',
        'node_modules',
        '.idea',
        'dist',
        'build',
        'out',
        'archives',
        'release',
        'doda-paks'
    ),

    [string[]]$ExcludeFiles = @(
        '*.tmp',
        '*.log',
        '*.bak',
        '*.pdb',
        '*.user',
        '*.suo'
    )
)

$ErrorActionPreference = 'Stop'

function Get-RelativePath {
    param([string]$Base, [string]$Full)
    $baseNorm = $Base.TrimEnd('\','/')
    $fullNorm = $Full
    return $fullNorm.Substring($baseNorm.Length).TrimStart('\','/')
}

function Get-AuditTxtPath {
    param([string]$Path)
    $dir = Split-Path $Path -Parent
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    Join-Path $dir ($base + '.txt')
}

if (!(Test-Path -LiteralPath $SourceRoot)) { throw "SourceRoot not found: $SourceRoot" }
if (!(Test-Path -LiteralPath $StagingRoot)) { throw "StagingRoot not found: $StagingRoot" }

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$runRoot = Join-Path $StagingRoot ('audit_' + $stamp)
New-Item -ItemType Directory -Force -Path $runRoot | Out-Null

$excludeDirArgs = @()
foreach ($d in $ExcludeDirs) { $excludeDirArgs += @('/XD', (Join-Path $SourceRoot $d)) }

$excludeFileArgs = @()
if ($ExcludeFiles.Count -gt 0) { $excludeFileArgs += '/XF'; $excludeFileArgs += $ExcludeFiles }

$rcArgs = @($SourceRoot, $runRoot, '/E', '/R:0', '/W:0', '/NFL', '/NDL', '/NJH', '/NJS', '/NP') + $excludeDirArgs + $excludeFileArgs
& robocopy @rcArgs | Out-Null
$rc = $LASTEXITCODE
if ($rc -ge 8) { throw "Robocopy failed with exit code $rc" }

Get-ChildItem -LiteralPath $runRoot -Recurse -File | Sort-Object FullName -Descending | ForEach-Object {
    $target = Get-AuditTxtPath -Path $_.FullName
    if ($_.FullName -ne $target) {
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
        Rename-Item -LiteralPath $_.FullName -NewName ([System.IO.Path]::GetFileName($target))
    }
}

function New-TreeNode {
    param([string]$Name, [string]$Path, [string]$Type)
    [ordered]@{ name = $Name; path = $Path; type = $Type; children = @() }
}

$tree = New-TreeNode -Name (Split-Path $runRoot -Leaf) -Path '' -Type 'directory'
$allItems = Get-ChildItem -LiteralPath $runRoot -Recurse -Force | Sort-Object FullName
foreach ($item in $allItems) {
    $rel = Get-RelativePath -Base $runRoot -Full $item.FullName
    $parts = $rel -split '[\\/]'
    $node = $tree
    for ($i = 0; $i -lt $parts.Length; $i++) {
        $part = $parts[$i]
        $isLast = ($i -eq $parts.Length - 1)
        if ($isLast -and $item.PSIsContainer) {
            $existing = $node.children | Where-Object { $_.name -eq $part -and $_.type -eq 'directory' } | Select-Object -First 1
            if (-not $existing) {
                $existing = New-TreeNode -Name $part -Path $rel -Type 'directory'
                $node.children += [pscustomobject]$existing
            }
        }
        elseif ($isLast -and -not $item.PSIsContainer) {
            $node.children += [pscustomobject][ordered]@{ name = $part; path = $rel; type = 'file'; size = $item.Length }
        }
        else {
            $existing = $node.children | Where-Object { $_.name -eq $part -and $_.type -eq 'directory' } | Select-Object -First 1
            if (-not $existing) {
                $subPath = ($parts[0..$i] -join [IO.Path]::DirectorySeparatorChar)
                $existing = New-TreeNode -Name $part -Path $subPath -Type 'directory'
                $node.children += [pscustomobject]$existing
            }
            $node = $existing
        }
    }
}

$files = Get-ChildItem -LiteralPath $runRoot -Recurse -File | ForEach-Object {
    [pscustomobject]@{ relativePath = Get-RelativePath -Base $runRoot -Full $_.FullName; name = $_.Name; size = $_.Length; extension = '.txt' }
}

$manifest = [pscustomobject]@{
    sourceRoot = $SourceRoot
    stagingRoot = $runRoot
    createdUtc = (Get-Date).ToUniversalTime().ToString('o')
    excludedDirs = $ExcludeDirs
    excludedFiles = $ExcludeFiles
    tree = $tree
    files = $files
}

$manifestPath = Join-Path $runRoot 'manifest.json'
$manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Output $runRoot