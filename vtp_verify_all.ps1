param(
  [string]$RepoRoot = ".",
  [string]$NodeId = "node-beta",
  [string]$To = "node-beta"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path $RepoRoot).Path
$Vtp = Join-Path $RepoRoot "vtp.ps1"
if(-not (Test-Path -LiteralPath $Vtp -PathType Leaf)){ throw "VTP_VERIFY_ALL_FAIL:MISSING_VTP_CLI" }

function Run-Step {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string[]]$ChildArgs
  )

  Write-Host ("VTP_VERIFY_STEP_START: " + $Name)
  & ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Vtp @ChildArgs
  if($LASTEXITCODE -ne 0){
    throw ("VTP_VERIFY_ALL_FAIL:" + $Name + ":EXIT_" + $LASTEXITCODE)
  }
  Write-Host ("VTP_VERIFY_STEP_OK: " + $Name)
}

Run-Step -Name "wire-key-test" -ChildArgs @("wire-key-test","-RepoRoot",$RepoRoot,"-To",$To)
Run-Step -Name "wire-smoke" -ChildArgs @("wire-smoke","-RepoRoot",$RepoRoot,"-To",$To)
Run-Step -Name "wire-ingest" -ChildArgs @("wire-ingest","-RepoRoot",$RepoRoot,"-To",$To)
Run-Step -Name "wire-negative" -ChildArgs @("wire-negative","-RepoRoot",$RepoRoot,"-To",$To)
Run-Step -Name "transmit" -ChildArgs @("transmit","-RepoRoot",$RepoRoot,"-To",$To)
Run-Step -Name "dlp-test" -ChildArgs @("dlp-test","-RepoRoot",$RepoRoot,"-NodeId",$NodeId)
Run-Step -Name "full-green" -ChildArgs @("full-green","-RepoRoot",$RepoRoot,"-To",$To)
Run-Step -Name "receipts" -ChildArgs @("receipts","-RepoRoot",$RepoRoot,"-NodeId",$NodeId)

Write-Host "VTP_VERIFY_ALL_OK"
