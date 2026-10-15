param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PSExe  = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$Script = Join-Path $PSScriptRoot "_selftest_vtp_negatives_v1.ps1"

$p = Start-Process -FilePath $PSExe -ArgumentList @(
  "-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass",
  "-File",$Script,
  "-RepoRoot",$RepoRoot
) -Wait -PassThru

if($p.ExitCode -ne 0){
  throw ("VTP_NEGATIVE_RUNNER_FAIL:EXIT_" + $p.ExitCode)
}

Write-Host "VTP_NEGATIVE_RUNNER_OK"
