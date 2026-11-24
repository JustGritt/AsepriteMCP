<#
.SYNOPSIS
    Run the shared aseprite-mcp HTTP server at logon, in the background.

.DESCRIPTION
    Registers a per-user scheduled task that starts this checkout's server
    (.venv\Scripts\pythonw.exe -m aseprite_mcp --http PORT, 127.0.0.1 only) at
    logon with no window, and starts it now. No admin rights needed. Point MCP
    clients at
    http://127.0.0.1:PORT/mcp. The task runs whatever branch is checked out:
    after pulling or switching branches,
    Stop-ScheduledTask aseprite-mcp; Start-ScheduledTask aseprite-mcp

.PARAMETER AllowedDirs
    ';'-separated directories saved as the user's ASEPRITE_MCP_ALLOWED_DIRS.
    Omit to keep the current value.

.PARAMETER Port
    MCP port for clients. The Aseprite bridge port (32145) is separate.

.PARAMETER Uninstall
    Stop and remove the task.
#>
[CmdletBinding()]
param(
    [string]$AllowedDirs,
    [int]$Port = 8766,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$name = 'aseprite-mcp'

if ($Uninstall) {
    Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $name -Confirm:$false
    Write-Host "Removed task $name."
    return
}

$repo = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $repo '.venv\Scripts\pythonw.exe'
if (-not (Test-Path $exe)) { throw "$exe not found. Run 'uv sync' in $repo first." }

if ($AllowedDirs) {
    [Environment]::SetEnvironmentVariable('ASEPRITE_MCP_ALLOWED_DIRS', $AllowedDirs, 'User')
}

$user = "$env:USERDOMAIN\$env:USERNAME"
# pythonw has no console window. Run it directly, not under a wrapper: stopping
# the task kills only its top process, and the venv launcher takes its child
# interpreter down with it.
$action = New-ScheduledTaskAction -Execute $exe -Argument "-m aseprite_mcp --http $Port" -WorkingDirectory $repo
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
# The defaults would kill it after 72 hours and on battery.
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $name

Write-Host "Task $name registered and started: http://127.0.0.1:$Port/mcp"
Write-Host "Allowed dirs: $([Environment]::GetEnvironmentVariable('ASEPRITE_MCP_ALLOWED_DIRS', 'User'))"
