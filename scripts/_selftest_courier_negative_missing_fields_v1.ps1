param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PSExe   = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$Scripts = Join-Path $RepoRoot "scripts"
$NegRoot = Join-Path $RepoRoot "test_vectors\courier_v1\negative\missing_fields"

$Msg       = Join-Path $RepoRoot "test_vectors\courier_v1\positive\msg.json"
$Lex       = Join-Path $RepoRoot "policies\lexicon\default_lexicon_v1.json"
$OutLex    = Join-Path $NegRoot "msg.lex.json"
$OutCommit = Join-Path $NegRoot "msg.commit.json"
$OutEnc    = Join-Path $NegRoot "msg.enc.json"

$ApplyScript   = Join-Path $Scripts "courier_apply_lexicon_v1.ps1"
$CommitScript  = Join-Path $Scripts "courier_commit_message_v1.ps1"
$EncryptScript = Join-Path $Scripts "courier_encrypt_message_v1.ps1"
$VerifyScript  = Join-Path $Scripts "courier_verify_message_v1.ps1"

. (Join-Path $Scripts "_lib_courier_v1.ps1")

function Run-Case {
  param(
    [Parameter(Mandatory=$true)][string]$CaseName,
    [Parameter(Mandatory=$true)][object]$BadObject,
    [Parameter(Mandatory=$true)][string]$ExpectedToken
  )

  $caseJson = Join-Path $NegRoot ($CaseName + ".json")
  $stdoutP  = Join-Path $NegRoot ($CaseName + ".stdout.txt")
  $stderrP  = Join-Path $NegRoot ($CaseName + ".stderr.txt")

  foreach($p in @($caseJson,$stdoutP,$stderrP)){
    if(Test-Path -LiteralPath $p){
      Remove-Item -LiteralPath $p -Force
    }
  }

  Write-JsonCanonical $caseJson $BadObject

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $PSExe
  $psi.Arguments = (
    '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -MessagePath "{1}" -RepoRoot "{2}"' -f
    $VerifyScript, $caseJson, $RepoRoot
  )
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.CreateNoWindow = $true

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi

  [void]$proc.Start()
  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()

  Write-Utf8NoBomLf $stdoutP $stdout
  Write-Utf8NoBomLf $stderrP $stderr

  if($proc.ExitCode -eq 0){
    throw ("NEG_FAIL:" + $CaseName + ":VERIFY_UNEXPECTED_SUCCESS")
  }

  $verifyText = ($stdout + "`n" + $stderr)
  if($verifyText -notmatch [regex]::Escape($ExpectedToken)){
    throw ("NEG_FAIL:" + $CaseName + ":WRONG_FAILURE_TOKEN:`n" + $verifyText)
  }

  Write-Host ("COURIER_NEGATIVE_MISSING_FIELD_OK: " + $CaseName + " -> " + $ExpectedToken)
}

if(-not (Test-Path -LiteralPath $NegRoot)){
  [void][System.IO.Directory]::CreateDirectory($NegRoot)
}

foreach($req in @($PSExe,$Msg,$Lex,$ApplyScript,$CommitScript,$EncryptScript,$VerifyScript)){
  if(-not (Test-Path -LiteralPath $req)){
    throw ("NEG_FAIL:MISSING_REQUIRED:" + $req)
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
if($LASTEXITCODE -ne 0){ throw ("NEG_FAIL:LEXICON_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $CommitScript `
  -MessagePath $OutLex `
  -OutPath $OutCommit `
  -RepoRoot $RepoRoot
if($LASTEXITCODE -ne 0){ throw ("NEG_FAIL:COMMIT_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $EncryptScript `
  -MessagePath $OutCommit `
  -OutPath $OutEnc `
  -RepoRoot $RepoRoot
if($LASTEXITCODE -ne 0){ throw ("NEG_FAIL:ENCRYPT_EXIT_" + $LASTEXITCODE) }

if(-not (Test-Path -LiteralPath $OutEnc)){
  throw "NEG_FAIL:ENCRYPT_OUTPUT_MISSING"
}

$msgObj = Read-Json $OutEnc

$baseObj = [ordered]@{
  created_utc        = [string]$msgObj.created_utc
  expires_utc        = [string]$msgObj.expires_utc
  hashes             = ConvertTo-StableObject $msgObj.hashes
  lexical_transforms = ConvertTo-StableObject $msgObj.lexical_transforms
  message_id         = [string]$msgObj.message_id
  payload            = ConvertTo-StableObject $msgObj.payload
  recipients         = ConvertTo-StableObject $msgObj.recipients
  schema             = [string]$msgObj.schema
  sender             = ConvertTo-StableObject $msgObj.sender
  sensitivity        = [string]$msgObj.sensitivity
  transport          = ConvertTo-StableObject $msgObj.transport
}

Run-Case `
  -CaseName "missing_hashes" `
  -ExpectedToken "VERIFY_FAIL:MISSING_HASHES" `
  -BadObject ([ordered]@{
    created_utc        = $baseObj.created_utc
    expires_utc        = $baseObj.expires_utc
    lexical_transforms = $baseObj.lexical_transforms
    message_id         = $baseObj.message_id
    payload            = $baseObj.payload
    recipients         = $baseObj.recipients
    schema             = $baseObj.schema
    sender             = $baseObj.sender
    sensitivity        = $baseObj.sensitivity
    transport          = $baseObj.transport
  })

Run-Case `
  -CaseName "missing_payload" `
  -ExpectedToken "VERIFY_FAIL:MISSING_PAYLOAD" `
  -BadObject ([ordered]@{
    created_utc        = $baseObj.created_utc
    expires_utc        = $baseObj.expires_utc
    hashes             = $baseObj.hashes
    lexical_transforms = $baseObj.lexical_transforms
    message_id         = $baseObj.message_id
    recipients         = $baseObj.recipients
    schema             = $baseObj.schema
    sender             = $baseObj.sender
    sensitivity        = $baseObj.sensitivity
    transport          = $baseObj.transport
  })

Run-Case `
  -CaseName "missing_transport" `
  -ExpectedToken "VERIFY_FAIL:MISSING_TRANSPORT" `
  -BadObject ([ordered]@{
    created_utc        = $baseObj.created_utc
    expires_utc        = $baseObj.expires_utc
    hashes             = $baseObj.hashes
    lexical_transforms = $baseObj.lexical_transforms
    message_id         = $baseObj.message_id
    payload            = $baseObj.payload
    recipients         = $baseObj.recipients
    schema             = $baseObj.schema
    sender             = $baseObj.sender
    sensitivity        = $baseObj.sensitivity
  })

Run-Case `
  -CaseName "missing_lexical_transforms" `
  -ExpectedToken "VERIFY_FAIL:MISSING_LEXICAL_TRANSFORMS" `
  -BadObject ([ordered]@{
    created_utc = $baseObj.created_utc
    expires_utc = $baseObj.expires_utc
    hashes      = $baseObj.hashes
    message_id  = $baseObj.message_id
    payload     = $baseObj.payload
    recipients  = $baseObj.recipients
    schema      = $baseObj.schema
    sender      = $baseObj.sender
    sensitivity = $baseObj.sensitivity
    transport   = $baseObj.transport
  })

Run-Case `
  -CaseName "missing_recipients" `
  -ExpectedToken "VERIFY_FAIL:MISSING_RECIPIENTS" `
  -BadObject ([ordered]@{
    created_utc        = $baseObj.created_utc
    expires_utc        = $baseObj.expires_utc
    hashes             = $baseObj.hashes
    lexical_transforms = $baseObj.lexical_transforms
    message_id         = $baseObj.message_id
    payload            = $baseObj.payload
    schema             = $baseObj.schema
    sender             = $baseObj.sender
    sensitivity        = $baseObj.sensitivity
    transport          = $baseObj.transport
  })

Write-Host "COURIER_NEGATIVE_MISSING_FIELDS_OK"