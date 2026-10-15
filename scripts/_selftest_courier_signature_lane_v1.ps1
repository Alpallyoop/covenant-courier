param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PSExe = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$Scripts = Join-Path $RepoRoot "scripts"

$BootstrapScript = Join-Path $Scripts "courier_bootstrap_local_trust_v1.ps1"
$SignScript      = Join-Path $Scripts "courier_sign_message_v1.ps1"
$VerifySigScript = Join-Path $Scripts "courier_verify_signature_v1.ps1"
$RunnerScript    = Join-Path $Scripts "FULL_GREEN_RUNNER_COURIER_v1.ps1"

$Msg = Join-Path $RepoRoot "test_vectors\courier_v1\positive\msg.enc.json"

foreach($req in @($PSExe,$BootstrapScript,$SignScript,$VerifySigScript,$RunnerScript)){
  if(-not (Test-Path -LiteralPath $req)){
    throw ("SIG_SELFTEST_FAIL:MISSING_REQUIRED:" + $req)
  }
}

# Ensure a fresh green encrypted message exists
& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $RunnerScript `
  -RepoRoot $RepoRoot
if($LASTEXITCODE -ne 0){
  throw ("SIG_SELFTEST_FAIL:RUNNER_EXIT_" + $LASTEXITCODE)
}

if(-not (Test-Path -LiteralPath $Msg)){
  throw "SIG_SELFTEST_FAIL:MISSING_ENCRYPTED_MESSAGE"
}

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $BootstrapScript `
  -RepoRoot $RepoRoot
if($LASTEXITCODE -ne 0){
  throw ("SIG_SELFTEST_FAIL:BOOTSTRAP_EXIT_" + $LASTEXITCODE)
}

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $SignScript `
  -RepoRoot $RepoRoot `
  -MessagePath $Msg
if($LASTEXITCODE -ne 0){
  throw ("SIG_SELFTEST_FAIL:SIGN_EXIT_" + $LASTEXITCODE)
}

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $VerifySigScript `
  -RepoRoot $RepoRoot `
  -MessagePath $Msg `
  -SignerIdentity "courier-local@covenant"
if($LASTEXITCODE -ne 0){
  throw ("SIG_SELFTEST_FAIL:VERIFY_SIG_EXIT_" + $LASTEXITCODE)
}

Write-Host "COURIER_SIGNATURE_LANE_SELFTEST_OK"