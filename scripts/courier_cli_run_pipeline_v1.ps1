param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$InputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PSExe = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)

$Run = Join-Path $RepoRoot "scripts\courier_run_message_pipeline_v1.ps1"

if(-not (Test-Path $Run)){
  throw "COURIER_PIPELINE_MISSING_CORE"
}

$p = Start-Process -FilePath $PSExe `
  -ArgumentList @(
    "-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass",
    "-File",$Run,
    "-RepoRoot",$RepoRoot,
    "-InputDir",$InputDir
  ) -NoNewWindow -Wait -PassThru

if($p.ExitCode -ne 0){
  throw ("COURIER_PIPELINE_FAIL:EXIT_" + $p.ExitCode)
}

Write-Host "COURIER_PIPELINE_OK"
