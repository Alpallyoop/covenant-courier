param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PSExe    = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$Scripts  = Join-Path $RepoRoot "scripts"
$NegRoot  = Join-Path $RepoRoot "test_vectors\courier_v1\negative\signature_tamper"

$RunnerScript    = Join-Path $Scripts "FULL_GREEN_RUNNER_COURIER_v1.ps1"
$BootstrapScript = Join-Path $Scripts "courier_bootstrap_local_trust_v1.ps1"
$SignScript      = Join-Path $Scripts "courier_sign_message_v1.ps1"
$VerifySigScript = Join-Path $Scripts "courier_verify_signature_v1.ps1"

$MsgSrc = Join-Path $RepoRoot "test_vectors\courier_v1\positive\msg.enc.json"
$MsgBad = Join-Path $NegRoot  "msg.enc.tampered.json"
$SigBad = $MsgBad + ".sig"

. (Join-Path $Scripts "_lib_courier_v1.ps1")

function Run-ChildCapture([string]$File,[string[]]$ChildArgs){
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $PSExe
  $psi.Arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" {1}' -f $File, ($ChildArgs -join " "))
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

  return [pscustomobject]@{
    ExitCode = $p.ExitCode
    StdOut   = $stdout
    StdErr   = $stderr
    Text     = ($stdout + "`n" + $stderr)
  }
}

Ensure-Dir $NegRoot

foreach($req in @($PSExe,$RunnerScript,$BootstrapScript,$SignScript,$VerifySigScript,$MsgSrc)){
  if(-not (Test-Path -LiteralPath $req)){
    throw ("NEG_SIG_FAIL:MISSING_REQUIRED:" + $req)
  }
}

foreach($p in @($MsgBad,$SigBad,
  (Join-Path $NegRoot "verify.stdout.txt"),
  (Join-Path $NegRoot "verify.stderr.txt"))){
  if(Test-Path -LiteralPath $p){
    Remove-Item -LiteralPath $p -Force
  }
}

$r1 = Run-ChildCapture $RunnerScript @('-RepoRoot', ('"{0}"' -f $RepoRoot))
if($r1.ExitCode -ne 0){
  throw ("NEG_SIG_FAIL:RUNNER_EXIT_" + $r1.ExitCode)
}

$r2 = Run-ChildCapture $BootstrapScript @('-RepoRoot', ('"{0}"' -f $RepoRoot))
if($r2.ExitCode -ne 0){
  throw ("NEG_SIG_FAIL:BOOTSTRAP_EXIT_" + $r2.ExitCode)
}

Copy-Item -LiteralPath $MsgSrc -Destination $MsgBad -Force

$r3 = Run-ChildCapture $SignScript @(
  '-RepoRoot', ('"{0}"' -f $RepoRoot),
  '-MessagePath', ('"{0}"' -f $MsgBad)
)
if($r3.ExitCode -ne 0){
  throw ("NEG_SIG_FAIL:SIGN_EXIT_" + $r3.ExitCode)
}

if(-not (Test-Path -LiteralPath $SigBad)){
  throw "NEG_SIG_FAIL:MISSING_SIG_AFTER_SIGN"
}

# Tamper the already signed message
$msgObj = Read-Json $MsgBad
$badObj = [ordered]@{
  created_utc        = [string]$msgObj.created_utc
  expires_utc        = [string]$msgObj.expires_utc
  hashes             = ConvertTo-StableObject $msgObj.hashes
  lexical_transforms = ConvertTo-StableObject $msgObj.lexical_transforms
  message_id         = [string]$msgObj.message_id
  payload            = [ordered]@{ type = "tampered_after_sign" }
  recipients         = ConvertTo-StableObject $msgObj.recipients
  schema             = [string]$msgObj.schema
  sender             = ConvertTo-StableObject $msgObj.sender
  sensitivity        = [string]$msgObj.sensitivity
  transport          = ConvertTo-StableObject $msgObj.transport
}
Write-JsonCanonical $MsgBad $badObj

$r4 = Run-ChildCapture $VerifySigScript @(
  '-RepoRoot', ('"{0}"' -f $RepoRoot),
  '-MessagePath', ('"{0}"' -f $MsgBad),
  '-SignerIdentity', '"courier-local@covenant"'
)

Write-Utf8NoBomLf (Join-Path $NegRoot "verify.stdout.txt") $r4.StdOut
Write-Utf8NoBomLf (Join-Path $NegRoot "verify.stderr.txt") $r4.StdErr

if($r4.ExitCode -eq 0){
  throw "NEG_SIG_FAIL:VERIFY_UNEXPECTED_SUCCESS"
}

if($r4.Text -notmatch 'COURIER_VERIFY_FAIL:SIG_VERIFY_FAIL'){
  throw ("NEG_SIG_FAIL:WRONG_FAILURE_TOKEN:`n" + $r4.Text)
}

Write-Host "COURIER_NEGATIVE_SIG_TAMPER_OK"