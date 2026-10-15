param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PSExe   = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$Scripts = Join-Path $RepoRoot "scripts"
$NegRoot = Join-Path $RepoRoot "test_vectors\courier_v1\negative\author_hash_tamper"

$Msg       = Join-Path $RepoRoot "test_vectors\courier_v1\positive\msg.json"
$Lex       = Join-Path $RepoRoot "policies\lexicon\default_lexicon_v1.json"
$OutLex    = Join-Path $NegRoot "msg.lex.json"
$OutCommit = Join-Path $NegRoot "msg.commit.json"
$OutEnc    = Join-Path $NegRoot "msg.enc.json"
$OutBad    = Join-Path $NegRoot "msg.enc.tampered.json"

$VerifyStdOut = Join-Path $NegRoot "verify.stdout.txt"
$VerifyStdErr = Join-Path $NegRoot "verify.stderr.txt"

$ApplyScript   = Join-Path $Scripts "courier_apply_lexicon_v1.ps1"
$CommitScript  = Join-Path $Scripts "courier_commit_message_v1.ps1"
$EncryptScript = Join-Path $Scripts "courier_encrypt_message_v1.ps1"
$VerifyScript  = Join-Path $Scripts "courier_verify_message_v1.ps1"

. (Join-Path $Scripts "_lib_courier_v1.ps1")

if(-not (Test-Path -LiteralPath $NegRoot)){
  [void][System.IO.Directory]::CreateDirectory($NegRoot)
}

foreach($req in @($PSExe,$Msg,$Lex,$ApplyScript,$CommitScript,$EncryptScript,$VerifyScript)){
  if(-not (Test-Path -LiteralPath $req)){
    throw ("NEG_FAIL:MISSING_REQUIRED:" + $req)
  }
}

foreach($p in @($OutLex,$OutCommit,$OutEnc,$OutBad,$VerifyStdOut,$VerifyStdErr)){
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

# Tamper author_hash deterministically
$msgObj = Read-Json $OutEnc

$badHashes = [ordered]@{
  author_hash             = ("f" * 64)
  lexical_transform_hash  = [string]$msgObj.hashes.lexical_transform_hash
  payload_hash            = [string]$msgObj.hashes.payload_hash
  recipient_binding_hash  = [string]$msgObj.hashes.recipient_binding_hash
}

$badObj = [ordered]@{
  created_utc        = [string]$msgObj.created_utc
  expires_utc        = [string]$msgObj.expires_utc
  hashes             = $badHashes
  lexical_transforms = ConvertTo-StableObject $msgObj.lexical_transforms
  message_id         = [string]$msgObj.message_id
  payload            = ConvertTo-StableObject $msgObj.payload
  recipients         = ConvertTo-StableObject $msgObj.recipients
  schema             = [string]$msgObj.schema
  sender             = ConvertTo-StableObject $msgObj.sender
  sensitivity        = [string]$msgObj.sensitivity
  transport          = ConvertTo-StableObject $msgObj.transport
}

Write-JsonCanonical $OutBad $badObj

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $PSExe
$psi.Arguments = (
  '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -MessagePath "{1}" -RepoRoot "{2}"' -f
  $VerifyScript, $OutBad, $RepoRoot
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

Write-Utf8NoBomLf $VerifyStdOut $stdout
Write-Utf8NoBomLf $VerifyStdErr $stderr

if($proc.ExitCode -eq 0){
  throw "NEG_FAIL:VERIFY_UNEXPECTED_SUCCESS"
}

$verifyText = ($stdout + "`n" + $stderr)

if($verifyText -notmatch 'VERIFY_FAIL:AUTHOR_HASH_MISMATCH'){
  throw ("NEG_FAIL:WRONG_FAILURE_TOKEN:`n" + $verifyText)
}

Write-Host "COURIER_NEGATIVE_AUTHOR_HASH_TAMPER_OK"