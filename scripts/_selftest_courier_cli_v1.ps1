param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PSExe = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$Cli   = Join-Path $RepoRoot "scripts\courier_cli_v1.ps1"

$ComposeIn = Join-Path $RepoRoot "test_vectors\courier_v1\pipeline\compose.input.json"
$DictIn    = Join-Path $RepoRoot "policies\lexicon\default_dictionary_v1.json"
$WorkRoot  = Join-Path $RepoRoot "test_vectors\courier_v1\cli\run"
$ComposeOut= Join-Path $WorkRoot "message.composed.json"
$DictOut   = Join-Path $WorkRoot "dictionary.built.json"
$TokOut    = Join-Path $WorkRoot "message.tokenized.json"
$DecOut    = Join-Path $WorkRoot "message.decoded.json"

function Fail([string]$Code){
  throw $Code
}

if(-not (Test-Path -LiteralPath $Cli)){
  Fail ("COURIER_CLI_SELFTEST_FAIL:MISSING_CLI:" + $Cli)
}

if(Test-Path -LiteralPath $WorkRoot){
  Remove-Item -LiteralPath $WorkRoot -Recurse -Force
}
[void][System.IO.Directory]::CreateDirectory($WorkRoot)

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $Cli `
  -RepoRoot $RepoRoot `
  -Command compose `
  -ComposePath $ComposeIn `
  -OutPath $ComposeOut
if($LASTEXITCODE -ne 0){ Fail ("COURIER_CLI_SELFTEST_FAIL:COMPOSE_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $Cli `
  -RepoRoot $RepoRoot `
  -Command build-dictionary `
  -DictionaryPath $DictIn `
  -OutPath $DictOut
if($LASTEXITCODE -ne 0){ Fail ("COURIER_CLI_SELFTEST_FAIL:BUILD_DICT_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $Cli `
  -RepoRoot $RepoRoot `
  -Command tokenize `
  -MessagePath $ComposeOut `
  -DictionaryPath $DictOut `
  -OutPath $TokOut `
  -Context internal
if($LASTEXITCODE -ne 0){ Fail ("COURIER_CLI_SELFTEST_FAIL:TOKENIZE_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $Cli `
  -RepoRoot $RepoRoot `
  -Command bootstrap-trust
if($LASTEXITCODE -ne 0){ Fail ("COURIER_CLI_SELFTEST_FAIL:BOOTSTRAP_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $Cli `
  -RepoRoot $RepoRoot `
  -Command sign `
  -MessagePath $TokOut
if($LASTEXITCODE -ne 0){ Fail ("COURIER_CLI_SELFTEST_FAIL:SIGN_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $Cli `
  -RepoRoot $RepoRoot `
  -Command verify-signature `
  -MessagePath $TokOut
if($LASTEXITCODE -ne 0){ Fail ("COURIER_CLI_SELFTEST_FAIL:VERIFY_SIG_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $Cli `
  -RepoRoot $RepoRoot `
  -Command decode `
  -MessagePath $TokOut `
  -DictionaryPath $DictOut `
  -OutPath $DecOut
if($LASTEXITCODE -ne 0){ Fail ("COURIER_CLI_SELFTEST_FAIL:DECODE_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $Cli `
  -RepoRoot $RepoRoot `
  -Command run-pipeline `
  -ComposePath $ComposeIn `
  -DictionaryPath $DictIn `
  -WorkRoot (Join-Path $WorkRoot "pipeline")
if($LASTEXITCODE -ne 0){ Fail ("COURIER_CLI_SELFTEST_FAIL:RUN_PIPELINE_EXIT_" + $LASTEXITCODE) }

$tokRaw = Get-Content -Raw -LiteralPath $TokOut
$decObj = Get-Content -Raw -LiteralPath $DecOut | ConvertFrom-Json

if($tokRaw -notmatch '\[\[predators_wolf_alpha\]\]'){
  Fail "COURIER_CLI_SELFTEST_FAIL:WOLF_TOKEN_MISSING"
}
if([string]$decObj.decoded_text -ne "wolf near oak and a rose marker"){
  Fail ("COURIER_CLI_SELFTEST_FAIL:DECODE_MISMATCH:" + [string]$decObj.decoded_text)
}

Write-Host "COURIER_CLI_SELFTEST_OK"
