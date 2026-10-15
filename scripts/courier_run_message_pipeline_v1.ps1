param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [string]$ComposePath,
  [string]$DictionaryPath,
  [string]$WorkRoot,
  # Legacy entry point: -InputDir <dir> runs the full pipeline into <dir> using the
  # repository's default compose input and lexicon dictionary.
  [string]$InputDir,
  [string]$SignerIdentity = "courier-local@covenant",
  [string]$Namespace = "courier/message"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path $RepoRoot).Path
if(-not [string]::IsNullOrWhiteSpace($InputDir)){
  if(-not [string]::IsNullOrWhiteSpace($WorkRoot) -and ($WorkRoot -ne $InputDir)){ throw "COURIER_PIPELINE_FAIL:CONFLICTING_WORKROOT_AND_INPUTDIR" }
  $WorkRoot = $InputDir
  if([string]::IsNullOrWhiteSpace($ComposePath)){ $ComposePath = Join-Path $RepoRoot "test_vectors\courier_v1\pipeline\compose.input.json" }
  if([string]::IsNullOrWhiteSpace($DictionaryPath)){ $DictionaryPath = Join-Path $RepoRoot "policies\lexicon\default_dictionary_v1.json" }
}
if([string]::IsNullOrWhiteSpace($ComposePath)){ throw "COURIER_PIPELINE_FAIL:MISSING_ARGUMENT:ComposePath" }
if([string]::IsNullOrWhiteSpace($DictionaryPath)){ throw "COURIER_PIPELINE_FAIL:MISSING_ARGUMENT:DictionaryPath" }
if([string]::IsNullOrWhiteSpace($WorkRoot)){ throw "COURIER_PIPELINE_FAIL:MISSING_ARGUMENT:WorkRoot" }
if(-not (Test-Path -LiteralPath $ComposePath -PathType Leaf)){ throw "COURIER_PIPELINE_FAIL:MISSING_COMPOSE_INPUT" }
if(-not (Test-Path -LiteralPath $DictionaryPath -PathType Leaf)){ throw "COURIER_PIPELINE_FAIL:MISSING_DICTIONARY_INPUT" }
[void][System.IO.Directory]::CreateDirectory($WorkRoot)

$composed = Join-Path $WorkRoot "message.composed.json"
$dictionary = Join-Path $WorkRoot "dictionary.built.json"
$tokenized = Join-Path $WorkRoot "message.tokenized.json"
$decoded = Join-Path $WorkRoot "message.decoded.json"

& (Join-Path $PSScriptRoot "courier_compose_message_v1.ps1") -RepoRoot $RepoRoot -ComposePath $ComposePath -OutPath $composed
& (Join-Path $PSScriptRoot "courier_build_lexical_dictionary_v1.ps1") -DictionaryPath $DictionaryPath -OutPath $dictionary
& (Join-Path $PSScriptRoot "courier_tokenize_message_v1.ps1") -MessagePath $composed -DictionaryPath $dictionary -OutPath $tokenized
& (Join-Path $PSScriptRoot "courier_decode_message_v1.ps1") -MessagePath $tokenized -DictionaryPath $dictionary -OutPath $decoded
& (Join-Path $PSScriptRoot "courier_bootstrap_local_trust_v1.ps1") -RepoRoot $RepoRoot -SignerIdentity $SignerIdentity
& (Join-Path $PSScriptRoot "courier_sign_message_v1.ps1") -RepoRoot $RepoRoot -MessagePath $tokenized -SignerIdentity $SignerIdentity -Namespace $Namespace
& (Join-Path $PSScriptRoot "courier_verify_signature_v1.ps1") -RepoRoot $RepoRoot -MessagePath $tokenized -SignerIdentity $SignerIdentity -Namespace $Namespace

foreach($path in @($composed,$dictionary,$tokenized,$decoded,($tokenized + ".sig"))){
  if(-not (Test-Path -LiteralPath $path -PathType Leaf)){
    throw ("COURIER_PIPELINE_FAIL:MISSING_OUTPUT:" + $path)
  }
}

Write-Host "COURIER_MESSAGE_PIPELINE_OK"
