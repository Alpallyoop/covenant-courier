param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PSExe   = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$Scripts = Join-Path $RepoRoot "scripts"

$Msg       = Join-Path $RepoRoot "test_vectors\courier_v1\positive\msg.json"
$Lex       = Join-Path $RepoRoot "policies\lexicon\default_lexicon_v1.json"
$OutLex    = Join-Path $RepoRoot "test_vectors\courier_v1\positive\msg.lex.json"
$OutCommit = Join-Path $RepoRoot "test_vectors\courier_v1\positive\msg.commit.json"
$OutEnc    = Join-Path $RepoRoot "test_vectors\courier_v1\positive\msg.enc.json"

$ApplyScript    = Join-Path $Scripts "courier_apply_lexicon_v1.ps1"
$CommitScript   = Join-Path $Scripts "courier_commit_message_v1.ps1"
$EncryptScript  = Join-Path $Scripts "courier_encrypt_message_v1.ps1"
$VerifyScript   = Join-Path $Scripts "courier_verify_message_v1.ps1"
$SenderScript   = Join-Path $Scripts "courier_sender_confirm_v1.ps1"
$ReceiverScript = Join-Path $Scripts "courier_receiver_confirm_v1.ps1"

$NegSealedScript    = Join-Path $Scripts "_selftest_courier_negative_sealed_payload_hash_tamper_v1.ps1"
$NegRecipientScript = Join-Path $Scripts "_selftest_courier_negative_recipient_binding_mismatch_v1.ps1"
$NegLexicalScript   = Join-Path $Scripts "_selftest_courier_negative_lexical_transform_tamper_v1.ps1"
$NegPayloadScript   = Join-Path $Scripts "_selftest_courier_negative_payload_hash_tamper_v1.ps1"
$NegAuthorScript    = Join-Path $Scripts "_selftest_courier_negative_author_hash_tamper_v1.ps1"
$NegMissingScript   = Join-Path $Scripts "_selftest_courier_negative_missing_fields_v1.ps1"

if(-not (Test-Path -LiteralPath $PSExe)){ throw ("SELFTEST_FAIL:MISSING_POWERSHELL:" + $PSExe) }
foreach($req in @(
  $Msg,$Lex,$ApplyScript,$CommitScript,$EncryptScript,$VerifyScript,
  $SenderScript,$ReceiverScript,
  $NegSealedScript,$NegRecipientScript,$NegLexicalScript,
  $NegPayloadScript,$NegAuthorScript,$NegMissingScript
)){
  if(-not (Test-Path -LiteralPath $req)){
    throw ("SELFTEST_FAIL:MISSING_REQUIRED:" + $req)
  }
}

foreach($p in @($OutLex,$OutCommit,$OutEnc)){
  if(Test-Path -LiteralPath $p){
    Remove-Item -LiteralPath $p -Force
  }
}

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $ApplyScript `
  -MessagePath $Msg `
  -LexiconPath $Lex `
  -OutPath $OutLex `
  -RepoRoot $RepoRoot
if($LASTEXITCODE -ne 0){ throw ("SELFTEST_FAIL:LEXICON_EXIT_" + $LASTEXITCODE) }

if(-not (Test-Path -LiteralPath $OutLex)){
  throw "SELFTEST_FAIL:LEXICON_OUTPUT_MISSING"
}

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $CommitScript `
  -MessagePath $OutLex `
  -OutPath $OutCommit `
  -RepoRoot $RepoRoot
if($LASTEXITCODE -ne 0){ throw ("SELFTEST_FAIL:COMMIT_EXIT_" + $LASTEXITCODE) }

if(-not (Test-Path -LiteralPath $OutCommit)){
  throw "SELFTEST_FAIL:COMMIT_OUTPUT_MISSING"
}

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $EncryptScript `
  -MessagePath $OutCommit `
  -OutPath $OutEnc `
  -RepoRoot $RepoRoot
if($LASTEXITCODE -ne 0){ throw ("SELFTEST_FAIL:ENCRYPT_EXIT_" + $LASTEXITCODE) }

if(-not (Test-Path -LiteralPath $OutEnc)){
  throw "SELFTEST_FAIL:ENCRYPT_OUTPUT_MISSING"
}

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $VerifyScript `
  -MessagePath $OutEnc `
  -RepoRoot $RepoRoot
if($LASTEXITCODE -ne 0){ throw ("SELFTEST_FAIL:VERIFY_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $SenderScript `
  -MessagePath $OutEnc `
  -RepoRoot $RepoRoot
if($LASTEXITCODE -ne 0){ throw ("SELFTEST_FAIL:SENDER_CONFIRM_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $ReceiverScript `
  -MessagePath $OutEnc `
  -RepoRoot $RepoRoot
if($LASTEXITCODE -ne 0){ throw ("SELFTEST_FAIL:RECEIVER_CONFIRM_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $NegSealedScript `
  -RepoRoot $RepoRoot
if($LASTEXITCODE -ne 0){ throw ("SELFTEST_FAIL:NEGATIVE_SEALED_HASH_TAMPER_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $NegRecipientScript `
  -RepoRoot $RepoRoot
if($LASTEXITCODE -ne 0){ throw ("SELFTEST_FAIL:NEGATIVE_RECIPIENT_BINDING_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $NegLexicalScript `
  -RepoRoot $RepoRoot
if($LASTEXITCODE -ne 0){ throw ("SELFTEST_FAIL:NEGATIVE_LEXICAL_TAMPER_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $NegPayloadScript `
  -RepoRoot $RepoRoot
if($LASTEXITCODE -ne 0){ throw ("SELFTEST_FAIL:NEGATIVE_PAYLOAD_TAMPER_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $NegAuthorScript `
  -RepoRoot $RepoRoot
if($LASTEXITCODE -ne 0){ throw ("SELFTEST_FAIL:NEGATIVE_AUTHOR_HASH_TAMPER_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $NegMissingScript `
  -RepoRoot $RepoRoot
if($LASTEXITCODE -ne 0){ throw ("SELFTEST_FAIL:NEGATIVE_MISSING_FIELDS_EXIT_" + $LASTEXITCODE) }

$lexed     = Get-Content -Raw -LiteralPath $OutLex
$committed = Get-Content -Raw -LiteralPath $OutCommit
$enc       = Get-Content -Raw -LiteralPath $OutEnc

if($lexed -notmatch '\[CAT:trees\]'){
  throw "SELFTEST_FAIL:TREE_TOKEN_MISSING"
}
if($lexed -notmatch '\[CAT:north_american_predators\]'){
  throw "SELFTEST_FAIL:PREDATOR_TOKEN_MISSING"
}
if($committed -notmatch '"payload_hash"'){
  throw "SELFTEST_FAIL:PAYLOAD_HASH_MISSING"
}
if($committed -notmatch '"author_hash"'){
  throw "SELFTEST_FAIL:AUTHOR_HASH_MISSING"
}
if($committed -notmatch '"recipient_binding_hash"'){
  throw "SELFTEST_FAIL:RECIPIENT_BINDING_HASH_MISSING"
}
if($enc -notmatch '"type":"sealed"'){
  throw "SELFTEST_FAIL:SEALED_TYPE_MISSING"
}
if($enc -notmatch '"sealed_payload_hash"'){
  throw "SELFTEST_FAIL:SEALED_PAYLOAD_HASH_MISSING"
}

Write-Host "COURIER_SELFTEST_OK"