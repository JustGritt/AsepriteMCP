<#
.SYNOPSIS
    Install the aseprite-mcp bridge extension for development.

.DESCRIPTION
    Copies extension/aseprite-mcp into the Aseprite extensions folder. Aseprite
    loads extensions at startup, so restart Aseprite afterwards.

    For a one-off install you can instead zip extension/aseprite-mcp as
    aseprite-mcp.aseprite-extension and use Edit > Preferences > Extensions >
    Add Extension. This script is the faster loop while developing.

.PARAMETER Link
    Create a directory junction instead of copying, so edits to the repo take
    effect on the next Aseprite restart with no reinstall.

.PARAMETER Uninstall
    Remove the installed extension.
#>
[CmdletBinding()]
param(
    [switch]$Link,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'extension\aseprite-mcp'
$extensionsDir = Join-Path $env:APPDATA 'Aseprite\extensions'
$target = Join-Path $extensionsDir 'aseprite-mcp'

if (-not (Test-Path $source)) {
    throw "Extension source not found at $source"
}

if (Test-Path $target) {
    Write-Host "Removing existing install at $target"
    # Junctions must be removed without recursing into the target.
    $item = Get-Item $target -Force
    if ($item.LinkType) {
        [System.IO.Directory]::Delete($target, $false)
    } else {
        Remove-Item -Recurse -Force $target
    }
}

if ($Uninstall) {
    Write-Host 'Uninstalled. Restart Aseprite to unload it.'
    return
}

if (-not (Test-Path $extensionsDir)) {
    New-Item -ItemType Directory -Force $extensionsDir | Out-Null
}

if ($Link) {
    New-Item -ItemType Junction -Path $target -Target $source | Out-Null
    Write-Host "Linked $target -> $source"
} else {
    Copy-Item -Recurse $source $target
    Write-Host "Copied to $target"
}

Write-Host ''
Write-Host 'Next steps:'
Write-Host '  1. Restart Aseprite.'
Write-Host '  2. If Aseprite asks whether the script may access files, allow it and'
Write-Host '     tick "Give full trust to this script". Previews are PNGs written to'
Write-Host '     disk, so rendering fails without it. See docs/SETUP.md.'
Write-Host '  3. Check File > MCP Bridge... -- it opens the connect dialog,'
Write-Host '     which reports status live and is where the host and port are set.'
