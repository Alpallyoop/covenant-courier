param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PSExe = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)

$BuildScript = Join-Path $RepoRoot "scripts\courier_build_lexical_dictionary_v1.ps1"
$TokenScript = Join-Path $RepoRoot "scripts\courier_tokenize_message_v1.ps1"
$DecodeScript= Join-Path $RepoRoot "scripts\courier_decode_message_v1.ps1"

$DictIn   = Join-Path $RepoRoot "policies\lexicon\default_dictionary_v1.json"
$DictOut  = Join-Path $RepoRoot "test_vectors\courier_v1\lexical\dictionary.built.json"
$MsgIn    = Join-Path $RepoRoot "test_vectors\courier_v1\lexical\message.plain.json"
$MsgTok   = Join-Path $RepoRoot "test_vectors\courier_v1\lexical\message.tokenized.json"
$MsgDec   = Join-Path $RepoRoot "test_vectors\courier_v1\lexical\message.decoded.json"

foreach($req in @($BuildScript,$TokenScript,$DecodeScript,$DictIn,$MsgIn)){
  if(-not (Test-Path -LiteralPath $req)){
    throw ("LEX_SELFTEST_FAIL:MISSING_REQUIRED:" + $req)
  }
}

foreach($p in @($DictOut,$MsgTok,$MsgDec)){
  if(Test-Path -LiteralPath $p){ Remove-Item -LiteralPath $p -Force }
}

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $BuildScript `
  -DictionaryPath $DictIn `
  -OutPath $DictOut
if($LASTEXITCODE -ne 0){ throw ("LEX_SELFTEST_FAIL:BUILD_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $TokenScript `
  -MessagePath $MsgIn `
  -DictionaryPath $DictOut `
  -OutPath $MsgTok `
  -Context internal
if($LASTEXITCODE -ne 0){ throw ("LEX_SELFTEST_FAIL:TOKENIZE_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $DecodeScript `
  -MessagePath $MsgTok `
  -DictionaryPath $DictOut `
  -OutPath $MsgDec
if($LASTEXITCODE -ne 0){ throw ("LEX_SELFTEST_FAIL:DECODE_EXIT_" + $LASTEXITCODE) }

$tokRaw = Get-Content -Raw -LiteralPath $MsgTok
$decObj = Get-Content -Raw -LiteralPath $MsgDec | ConvertFrom-Json

if($tokRaw -notmatch '\[\[predators_wolf_alpha\]\]'){
  throw "LEX_SELFTEST_FAIL:WOLF_TOKEN_MISSING"
}
if($tokRaw -notmatch '\[\[trees_oak_alpha\]\]'){
  throw "LEX_SELFTEST_FAIL:OAK_TOKEN_MISSING"
}
if($tokRaw -notmatch '\[\[flowers_rose_alpha\]\]'){
  throw "LEX_SELFTEST_FAIL:ROSE_TOKEN_MISSING"
}

$expectedDecoded = "wolf near oak and a rose marker"
$actualDecoded = [string]$decObj.decoded_text

if($actualDecoded -ne $expectedDecoded){
  throw ("LEX_SELFTEST_FAIL:DECODE_OUTPUT_MISMATCH: expected=[" + $expectedDecoded + "] actual=[" + $actualDecoded + "]")
}

Write-Host "COURIER_LEXICAL_DICTIONARY_SELFTEST_OK"