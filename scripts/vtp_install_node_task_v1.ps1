param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [string]$NodeId = "node-beta",
  [string]$TaskName = "VTP Node Loop"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path $RepoRoot).Path
$LoopPath = Join-Path $RepoRoot "scripts\vtp_node_loop_forever_v1.ps1"
if(-not (Test-Path -LiteralPath $LoopPath -PathType Leaf)){
  throw "VTP_INSTALL_TASK_FAIL:MISSING_LOOP_FOREVER"
}

$PSExe = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)

$Action = New-ScheduledTaskAction `
  -Execute $PSExe `
  -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $LoopPath + '" -RepoRoot "' + $RepoRoot + '" -NodeId "' + $NodeId + '" -IntervalSeconds 30')

$Trigger = New-ScheduledTaskTrigger -AtLogOn

$Settings = New-ScheduledTaskSettingsSet `
  -StartWhenAvailable `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -MultipleInstances IgnoreNew

$Principal = New-ScheduledTaskPrincipal `
  -UserId $env:USERNAME `
  -LogonType Interactive `
  -RunLevel Limited

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName

Write-Host ("VTP_NODE_TASK_INSTALLED: " + $TaskName)
Write-Host "VTP_NODE_TASK_MODE: FOREVER_LOOP_AT_LOGON"