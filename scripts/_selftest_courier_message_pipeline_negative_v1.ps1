param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PSExe      = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$Scripts    = Join-Path $RepoRoot "scripts"
$NegRoot    = Join-Path $RepoRoot "test_vectors\courier_v1\pipeline_negative"
$PolicyRoot = Join-Path $RepoRoot "policies\lexicon"

$ComposeScript   = Join-Path $Scripts "courier_compose_message_v1.ps1"
$BuildDictScript = Join-Path $Scripts "courier_build_lexical_dictionary_v1.ps1"
$TokenizeScript  = Join-Path $Scripts "courier_tokenize_message_v1.ps1"
$DecodeScript    = Join-Path $Scripts "courier_decode_message_v1.ps1"
$BootstrapScript = Join-Path $Scripts "courier_bootstrap_local_trust_v1.ps1"
$SignScript      = Join-Path $Scripts "courier_sign_message_v1.ps1"
$VerifySigScript = Join-Path $Scripts "courier_verify_signature_v1.ps1"

. (Join-Path $Scripts "_lib_courier_v1.ps1")

function Run-ChildCapture {
  param(
    [Parameter(Mandatory=$true)][string]$File,
    [Parameter(Mandatory=$true)][string]$ArgumentString
  )

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $PSExe
  $psi.Arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" {1}' -f $File, $ArgumentString)
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.CreateNoWindow = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()
  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()

  [pscustomobject]@{
    ExitCode = $p.ExitCode
    StdOut   = $stdout
    StdErr   = $stderr
    Text     = ($stdout + "`n" + $stderr)
  }
}

function New-BaseCompose {
  [ordered]@{
    created_utc    = "2026-01-01T00:00:00Z"
    dictionary_ref = "courier-default-dictionary"
    message_id     = "compose-neg-001"
    plaintext      = "wolf near oak tree and a rose marker"
    recipients     = @(
      [ordered]@{
        principal = "recipient-a"
        type      = "user"
      }
    )
    schema         = "courier.compose_message.v1"
    sender         = [ordered]@{
      principal = "courier-local@covenant"
    }
  }
}

function Assert-FailToken {
  param(
    [Parameter(Mandatory=$true)][string]$CaseName,
    [Parameter(Mandatory=$true)][string]$Expected,
    [Parameter(Mandatory=$true)][pscustomobject]$Result
  )

  if($Result.ExitCode -eq 0){
    throw ("PIPE_NEG_FAIL:" + $CaseName + ":UNEXPECTED_SUCCESS")
  }
  if($Result.Text -notmatch [regex]::Escape($Expected)){
    throw ("PIPE_NEG_FAIL:" + $CaseName + ":WRONG_FAILURE_TOKEN:`n" + $Result.Text)
  }

  Write-Host ("COURIER_PIPELINE_NEGATIVE_OK: " + $CaseName + " -> " + $Expected)
}

Ensure-Dir $NegRoot

foreach($req in @(
  $PSExe,$ComposeScript,$BuildDictScript,$TokenizeScript,$DecodeScript,
  $BootstrapScript,$SignScript,$VerifySigScript
)){
  if(-not (Test-Path -LiteralPath $req)){
    throw ("PIPE_NEG_FAIL:MISSING_REQUIRED:" + $req)
  }
}

# Bootstrap trust once with a direct call
& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $BootstrapScript `
  -RepoRoot $RepoRoot
if($LASTEXITCODE -ne 0){
  throw ("PIPE_NEG_FAIL:BOOTSTRAP_EXIT_" + $LASTEXITCODE)
}

# 1) missing plaintext
$case1 = Join-Path $NegRoot "compose.missing_plaintext.json"
$obj1 = New-BaseCompose
$obj1.Remove("plaintext")
Write-JsonCanonical $case1 $obj1

$r1 = Run-ChildCapture `
  -File $ComposeScript `
  -ArgumentString ('-ComposePath "{0}" -OutPath "{1}" -RepoRoot "{2}"' -f
    $case1, (Join-Path $NegRoot "out1.json"), $RepoRoot)

Assert-FailToken "missing_plaintext" "COURIER_COMPOSE_FAIL:MISSING_PLAINTEXT" $r1

# 2) missing recipients
$case2 = Join-Path $NegRoot "compose.missing_recipients.json"
$obj2 = New-BaseCompose
$obj2.Remove("recipients")
Write-JsonCanonical $case2 $obj2

$r2 = Run-ChildCapture `
  -File $ComposeScript `
  -ArgumentString ('-ComposePath "{0}" -OutPath "{1}" -RepoRoot "{2}"' -f
    $case2, (Join-Path $NegRoot "out2.json"), $RepoRoot)

Assert-FailToken "missing_recipients" "COURIER_COMPOSE_FAIL:MISSING_RECIPIENTS" $r2

# Setup clean artifacts for later negatives
$composeOk      = Join-Path $NegRoot "compose.valid.json"
$composed       = Join-Path $NegRoot "message.composed.json"
$dictBuilt      = Join-Path $NegRoot "dictionary.built.json"
$tokenized      = Join-Path $NegRoot "message.tokenized.json"
$decoded        = Join-Path $NegRoot "message.decoded.json"
$defaultDict    = Join-Path $RepoRoot "policies\lexicon\default_dictionary_v1.json"
$restrictedDict = Join-Path $PolicyRoot "restricted_dictionary_v1.json"

Write-JsonCanonical $composeOk (New-BaseCompose)

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $ComposeScript `
  -ComposePath $composeOk `
  -OutPath $composed `
  -RepoRoot $RepoRoot
if($LASTEXITCODE -ne 0){ throw ("PIPE_NEG_FAIL:SETUP_COMPOSE_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $BuildDictScript `
  -DictionaryPath $defaultDict `
  -OutPath $dictBuilt
if($LASTEXITCODE -ne 0){ throw ("PIPE_NEG_FAIL:SETUP_BUILD_DICT_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $TokenizeScript `
  -MessagePath $composed `
  -DictionaryPath $dictBuilt `
  -OutPath $tokenized `
  -Context internal
if($LASTEXITCODE -ne 0){ throw ("PIPE_NEG_FAIL:SETUP_TOKENIZE_EXIT_" + $LASTEXITCODE) }

# 3) missing dictionary path
$r3 = Run-ChildCapture `
  -File $TokenizeScript `
  -ArgumentString ('-MessagePath "{0}" -DictionaryPath "{1}" -OutPath "{2}" -Context internal' -f
    $composed, (Join-Path $NegRoot "does_not_exist.json"), (Join-Path $NegRoot "out3.json"))

Assert-FailToken "missing_dictionary" "MISSING_JSON_FILE:" $r3

# 4) disallowed context
$restrictedBuilt = Join-Path $NegRoot "restricted.built.json"

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $BuildDictScript `
  -DictionaryPath $restrictedDict `
  -OutPath $restrictedBuilt
if($LASTEXITCODE -ne 0){ throw ("PIPE_NEG_FAIL:RESTRICTED_BUILD_EXIT_" + $LASTEXITCODE) }

$out4 = Join-Path $NegRoot "out4.json"
& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $TokenizeScript `
  -MessagePath $composed `
  -DictionaryPath $restrictedBuilt `
  -OutPath $out4 `
  -Context internal
if($LASTEXITCODE -ne 0){
  throw ("PIPE_NEG_FAIL:DISALLOWED_CONTEXT_UNEXPECTED_EXIT_" + $LASTEXITCODE)
}

$out4Raw = Get-Content -Raw -LiteralPath $out4
if($out4Raw -match '\[\['){
  throw "PIPE_NEG_FAIL:DISALLOWED_CONTEXT_TOKEN_PRESENT"
}
Write-Host "COURIER_PIPELINE_NEGATIVE_OK: disallowed_context -> NO_TOKENIZATION"

# 5) tamper after sign
& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $SignScript `
  -RepoRoot $RepoRoot `
  -MessagePath $tokenized
if($LASTEXITCODE -ne 0){ throw ("PIPE_NEG_FAIL:SIGN_SETUP_EXIT_" + $LASTEXITCODE) }

$tokObj = Read-Json $tokenized
$tokObj.tokenized_text = ([string]$tokObj.tokenized_text + " tampered")
Write-JsonCanonical $tokenized $tokObj

$r5 = Run-ChildCapture `
  -File $VerifySigScript `
  -ArgumentString ('-RepoRoot "{0}" -MessagePath "{1}" -SignerIdentity "courier-local@covenant"' -f $RepoRoot, $tokenized)

Assert-FailToken "tamper_after_sign" "COURIER_VERIFY_FAIL:SIG_VERIFY_FAIL" $r5

# rebuild clean tokenized message
& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $TokenizeScript `
  -MessagePath $composed `
  -DictionaryPath $dictBuilt `
  -OutPath $tokenized `
  -Context internal
if($LASTEXITCODE -ne 0){ throw ("PIPE_NEG_FAIL:RETOKENIZE_EXIT_" + $LASTEXITCODE) }

# 6) decode with mismatched dictionary
$restrictedDecodeBuilt = Join-Path $NegRoot "restricted_decode.built.json"

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $BuildDictScript `
  -DictionaryPath $restrictedDict `
  -OutPath $restrictedDecodeBuilt
if($LASTEXITCODE -ne 0){ throw ("PIPE_NEG_FAIL:RESTRICTED_DECODE_BUILD_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $DecodeScript `
  -MessagePath $tokenized `
  -DictionaryPath $restrictedDecodeBuilt `
  -OutPath $decoded
if($LASTEXITCODE -ne 0){
  throw ("PIPE_NEG_FAIL:DECODE_MISMATCH_UNEXPECTED_EXIT_" + $LASTEXITCODE)
}

$decObj = Get-Content -Raw -LiteralPath $decoded | ConvertFrom-Json
if([string]$decObj.decoded_text -eq "wolf near oak and a rose marker"){
  throw "PIPE_NEG_FAIL:DECODE_MISMATCH_UNEXPECTED_SUCCESS"
}
Write-Host "COURIER_PIPELINE_NEGATIVE_OK: decode_mismatched_dictionary -> DIFFERENT_DECODE"

# 7) missing signature
& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $SignScript `
  -RepoRoot $RepoRoot `
  -MessagePath $tokenized
if($LASTEXITCODE -ne 0){ throw ("PIPE_NEG_FAIL:SIGN_FOR_MISSING_SIG_EXIT_" + $LASTEXITCODE) }

$sigPath = $tokenized + ".sig"
if(Test-Path -LiteralPath $sigPath){
  Remove-Item -LiteralPath $sigPath -Force
}

$r7 = Run-ChildCapture `
  -File $VerifySigScript `
  -ArgumentString ('-RepoRoot "{0}" -MessagePath "{1}" -SignerIdentity "courier-local@covenant"' -f $RepoRoot, $tokenized)

Assert-FailToken "missing_signature" "COURIER_VERIFY_FAIL:MISSING_SIGNATURE" $r7

Write-Host "COURIER_MESSAGE_PIPELINE_NEGATIVE_SUITE_OK"