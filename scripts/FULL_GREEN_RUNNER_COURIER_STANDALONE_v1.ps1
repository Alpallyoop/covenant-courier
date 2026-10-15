param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PSExe = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$Scripts = Join-Path $RepoRoot "scripts"

$CoreRunner     = Join-Path $Scripts "FULL_GREEN_RUNNER_COURIER_v1.ps1"
$SigLane        = Join-Path $Scripts "_selftest_courier_signature_lane_v1.ps1"
$LexLane        = Join-Path $Scripts "_selftest_courier_lexical_dictionary_v1.ps1"
$PipelineLane   = Join-Path $Scripts "_selftest_courier_message_pipeline_v1.ps1"
$PipelineNeg    = Join-Path $Scripts "_selftest_courier_message_pipeline_negative_v1.ps1"

function Fail([string]$Code){
  throw $Code
}

foreach($req in @($PSExe,$CoreRunner,$SigLane,$LexLane,$PipelineLane,$PipelineNeg)){
  if(-not (Test-Path -LiteralPath $req)){
    Fail ("COURIER_STANDALONE_FAIL:MISSING_REQUIRED:" + $req)
  }
}

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $CoreRunner `
  -RepoRoot $RepoRoot
if($LASTEXITCODE -ne 0){
  Fail ("COURIER_STANDALONE_FAIL:CORE_RUNNER_EXIT_" + $LASTEXITCODE)
}

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $SigLane `
  -RepoRoot $RepoRoot
if($LASTEXITCODE -ne 0){
  Fail ("COURIER_STANDALONE_FAIL:SIGNATURE_LANE_EXIT_" + $LASTEXITCODE)
}

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $LexLane `
  -RepoRoot $RepoRoot
if($LASTEXITCODE -ne 0){
  Fail ("COURIER_STANDALONE_FAIL:LEXICAL_LANE_EXIT_" + $LASTEXITCODE)
}

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $PipelineLane `
  -RepoRoot $RepoRoot
if($LASTEXITCODE -ne 0){
  Fail ("COURIER_STANDALONE_FAIL:PIPELINE_LANE_EXIT_" + $LASTEXITCODE)
}

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $PipelineNeg `
  -RepoRoot $RepoRoot
if($LASTEXITCODE -ne 0){
  Fail ("COURIER_STANDALONE_FAIL:PIPELINE_NEGATIVE_EXIT_" + $LASTEXITCODE)
}

Write-Host "COURIER_STANDALONE_ALL_GREEN"
