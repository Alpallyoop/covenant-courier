param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PSExe = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)

$RunScript = Join-Path $RepoRoot "scripts\courier_run_message_pipeline_v1.ps1"
$ComposeIn = Join-Path $RepoRoot "test_vectors\courier_v1\pipeline\compose.input.json"
$DictIn    = Join-Path $RepoRoot "policies\lexicon\default_dictionary_v1.json"
$WorkRoot  = Join-Path $RepoRoot "test_vectors\courier_v1\pipeline\run"

foreach($req in @($RunScript,$ComposeIn,$DictIn)){
  if(-not (Test-Path -LiteralPath $req)){
    throw ("COURIER_PIPELINE_SELFTEST_FAIL:MISSING_REQUIRED:" + $req)
  }
}

if(Test-Path -LiteralPath $WorkRoot){
  Remove-Item -LiteralPath $WorkRoot -Recurse -Force
}

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $RunScript `
  -RepoRoot $RepoRoot `
  -ComposePath $ComposeIn `
  -DictionaryPath $DictIn `
  -WorkRoot $WorkRoot
if($LASTEXITCODE -ne 0){ throw ("COURIER_PIPELINE_SELFTEST_FAIL:RUN_EXIT_" + $LASTEXITCODE) }

$Composed  = Join-Path $WorkRoot "message.composed.json"
$DictBuilt = Join-Path $WorkRoot "dictionary.built.json"
$Tokenized = Join-Path $WorkRoot "message.tokenized.json"
$Decoded   = Join-Path $WorkRoot "message.decoded.json"
$SigPath   = $Tokenized + ".sig"

foreach($p in @($Composed,$DictBuilt,$Tokenized,$Decoded,$SigPath)){
  if(-not (Test-Path -LiteralPath $p)){
    throw ("COURIER_PIPELINE_SELFTEST_FAIL:MISSING_OUTPUT:" + $p)
  }
}

$tokRaw = Get-Content -Raw -LiteralPath $Tokenized
$decObj = Get-Content -Raw -LiteralPath $Decoded | ConvertFrom-Json

if($tokRaw -notmatch '\[\[predators_wolf_alpha\]\]'){
  throw "COURIER_PIPELINE_SELFTEST_FAIL:WOLF_TOKEN_MISSING"
}
if($tokRaw -notmatch '\[\[trees_oak_alpha\]\]'){
  throw "COURIER_PIPELINE_SELFTEST_FAIL:OAK_TOKEN_MISSING"
}
if($tokRaw -notmatch '\[\[flowers_rose_alpha\]\]'){
  throw "COURIER_PIPELINE_SELFTEST_FAIL:ROSE_TOKEN_MISSING"
}

$expectedDecoded = "wolf near oak and a rose marker"
$actualDecoded = [string]$decObj.decoded_text

if($actualDecoded -ne $expectedDecoded){
  throw ("COURIER_PIPELINE_SELFTEST_FAIL:DECODE_MISMATCH expected=[" + $expectedDecoded + "] actual=[" + $actualDecoded + "]")
}

Write-Host "COURIER_MESSAGE_PIPELINE_SELFTEST_OK"
