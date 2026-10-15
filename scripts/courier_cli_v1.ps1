param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$Command,

  [string]$ComposePath,
  [string]$MessagePath,
  [string]$DictionaryPath,
  [string]$OutPath,
  [string]$WorkRoot,
  [string]$Context = "internal",
  [string]$SignerIdentity = "courier-local@covenant",
  [string]$Namespace = "courier/message"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PSExe = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$Scripts = Join-Path $RepoRoot "scripts"

function Fail([string]$Code){
  throw $Code
}

function Run-Step([string]$ScriptPath,[string]$ArgLine){
  if(-not (Test-Path -LiteralPath $ScriptPath)){
    Fail ("COURIER_CLI_FAIL:MISSING_SCRIPT:" + $ScriptPath)
  }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $PSExe
  $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"" + $ScriptPath + "`" " + $ArgLine
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $false
  $psi.RedirectStandardError  = $false

  $p = [System.Diagnostics.Process]::Start($psi)
  $p.WaitForExit()

  if($p.ExitCode -ne 0){
    Fail ("COURIER_CLI_FAIL:STEP_EXIT_" + $p.ExitCode + ":" + [System.IO.Path]::GetFileName($ScriptPath))
  }
}

$ComposeScript   = Join-Path $Scripts "courier_compose_message_v1.ps1"
$BuildDictScript = Join-Path $Scripts "courier_build_lexical_dictionary_v1.ps1"
$TokenizeScript  = Join-Path $Scripts "courier_tokenize_message_v1.ps1"
$DecodeScript    = Join-Path $Scripts "courier_decode_message_v1.ps1"
$BootstrapScript = Join-Path $Scripts "courier_bootstrap_local_trust_v1.ps1"
$SignScript      = Join-Path $Scripts "courier_sign_message_v1.ps1"
$VerifySigScript = Join-Path $Scripts "courier_verify_signature_v1.ps1"
$RunPipeScript   = Join-Path $Scripts "courier_run_message_pipeline_v1.ps1"
$StandaloneSelf  = Join-Path $Scripts "FULL_GREEN_RUNNER_COURIER_STANDALONE_v1.ps1"

switch ($Command.ToLowerInvariant()) {
  "compose" {
    if([string]::IsNullOrWhiteSpace($ComposePath)){ Fail "COURIER_CLI_FAIL:MISSING_COMPOSE_PATH" }
    if([string]::IsNullOrWhiteSpace($OutPath)){ Fail "COURIER_CLI_FAIL:MISSING_OUT_PATH" }
    Run-Step $ComposeScript @("-ComposePath",$ComposePath,"-OutPath",$OutPath,"-RepoRoot",$RepoRoot)
    Write-Host "COURIER_CLI_COMPOSE_OK"
  }

  "build-dictionary" {
    if([string]::IsNullOrWhiteSpace($DictionaryPath)){ Fail "COURIER_CLI_FAIL:MISSING_DICTIONARY_PATH" }
    if([string]::IsNullOrWhiteSpace($OutPath)){ Fail "COURIER_CLI_FAIL:MISSING_OUT_PATH" }
    Run-Step $BuildDictScript @("-DictionaryPath",$DictionaryPath,"-OutPath",$OutPath)
    Write-Host "COURIER_CLI_BUILD_DICTIONARY_OK"
  }

  "tokenize" {
    if([string]::IsNullOrWhiteSpace($MessagePath)){ Fail "COURIER_CLI_FAIL:MISSING_MESSAGE_PATH" }
    if([string]::IsNullOrWhiteSpace($DictionaryPath)){ Fail "COURIER_CLI_FAIL:MISSING_DICTIONARY_PATH" }
    if([string]::IsNullOrWhiteSpace($OutPath)){ Fail "COURIER_CLI_FAIL:MISSING_OUT_PATH" }
    Run-Step $TokenizeScript @("-MessagePath",$MessagePath,"-DictionaryPath",$DictionaryPath,"-OutPath",$OutPath,"-Context",$Context)
    Write-Host "COURIER_CLI_TOKENIZE_OK"
  }

  "decode" {
    if([string]::IsNullOrWhiteSpace($MessagePath)){ Fail "COURIER_CLI_FAIL:MISSING_MESSAGE_PATH" }
    if([string]::IsNullOrWhiteSpace($DictionaryPath)){ Fail "COURIER_CLI_FAIL:MISSING_DICTIONARY_PATH" }
    if([string]::IsNullOrWhiteSpace($OutPath)){ Fail "COURIER_CLI_FAIL:MISSING_OUT_PATH" }
    Run-Step $DecodeScript @("-MessagePath",$MessagePath,"-DictionaryPath",$DictionaryPath,"-OutPath",$OutPath)
    Write-Host "COURIER_CLI_DECODE_OK"
  }

  "bootstrap-trust" {
    Run-Step $BootstrapScript @("-RepoRoot",$RepoRoot,"-SignerIdentity",$SignerIdentity)
    Write-Host "COURIER_CLI_BOOTSTRAP_TRUST_OK"
  }

  "sign" {
    if([string]::IsNullOrWhiteSpace($MessagePath)){ Fail "COURIER_CLI_FAIL:MISSING_MESSAGE_PATH" }
    Run-Step $SignScript @("-RepoRoot",$RepoRoot,"-MessagePath",$MessagePath,"-SignerIdentity",$SignerIdentity,"-Namespace",$Namespace)
    Write-Host "COURIER_CLI_SIGN_OK"
  }

  "verify-signature" {
    if([string]::IsNullOrWhiteSpace($MessagePath)){ Fail "COURIER_CLI_FAIL:MISSING_MESSAGE_PATH" }
    Run-Step $VerifySigScript @("-RepoRoot",$RepoRoot,"-MessagePath",$MessagePath,"-SignerIdentity",$SignerIdentity,"-Namespace",$Namespace)
    Write-Host "COURIER_CLI_VERIFY_SIGNATURE_OK"
  }

  "run-pipeline" {
    if([string]::IsNullOrWhiteSpace($ComposePath)){ Fail "COURIER_CLI_FAIL:MISSING_COMPOSE_PATH" }
    if([string]::IsNullOrWhiteSpace($DictionaryPath)){ Fail "COURIER_CLI_FAIL:MISSING_DICTIONARY_PATH" }
    if([string]::IsNullOrWhiteSpace($WorkRoot)){ Fail "COURIER_CLI_FAIL:MISSING_WORKROOT" }
    Run-Step $RunPipeScript @("-RepoRoot",$RepoRoot,"-ComposePath",$ComposePath,"-DictionaryPath",$DictionaryPath,"-WorkRoot",$WorkRoot)
    Write-Host "COURIER_CLI_RUN_PIPELINE_OK"
  }

  "selftest-standalone" {
    Run-Step $StandaloneSelf @("-RepoRoot",$RepoRoot)
    Write-Host "COURIER_CLI_SELFTEST_STANDALONE_OK"
  }

  default {
    Fail ("COURIER_CLI_FAIL:UNKNOWN_COMMAND:" + $Command)
  }
}
