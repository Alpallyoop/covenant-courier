param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PSExe    = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$Scripts  = Join-Path $RepoRoot "scripts"
$NegRoot  = Join-Path $RepoRoot "test_vectors\courier_v1\negative\untrusted_signer"

$RunnerScript    = Join-Path $Scripts "FULL_GREEN_RUNNER_COURIER_v1.ps1"
$BootstrapScript = Join-Path $Scripts "courier_bootstrap_local_trust_v1.ps1"
$SignScript      = Join-Path $Scripts "courier_sign_message_v1.ps1"
$VerifySigScript = Join-Path $Scripts "courier_verify_signature_v1.ps1"

$Msg = Join-Path $RepoRoot "test_vectors\courier_v1\positive\msg.enc.json"

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

foreach($req in @($PSExe,$RunnerScript,$BootstrapScript,$SignScript,$VerifySigScript,$Msg)){
  if(-not (Test-Path -LiteralPath $req)){
    throw ("NEG_SIG_FAIL:MISSING_REQUIRED:" + $req)
  }
}

$r1 = Run-ChildCapture $RunnerScript @('-RepoRoot', ('"{0}"' -f $RepoRoot))
if($r1.ExitCode -ne 0){
  throw ("NEG_SIG_FAIL:RUNNER_EXIT_" + $r1.ExitCode)
}

$r2 = Run-ChildCapture $BootstrapScript @(
  '-RepoRoot', ('"{0}"' -f $RepoRoot),
  '-SignerIdentity', '"courier-other@covenant"'
)
if($r2.ExitCode -ne 0){
  throw ("NEG_SIG_FAIL:BOOTSTRAP_OTHER_EXIT_" + $r2.ExitCode)
}

$r3 = Run-ChildCapture $SignScript @(
  '-RepoRoot', ('"{0}"' -f $RepoRoot),
  '-MessagePath', ('"{0}"' -f $Msg),
  '-SignerIdentity', '"courier-other@covenant"'
)
if($r3.ExitCode -ne 0){
  throw ("NEG_SIG_FAIL:SIGN_OTHER_EXIT_" + $r3.ExitCode)
}

$r4 = Run-ChildCapture $VerifySigScript @(
  '-RepoRoot', ('"{0}"' -f $RepoRoot),
  '-MessagePath', ('"{0}"' -f $Msg),
  '-SignerIdentity', '"courier-local@covenant"'
)

Write-Utf8NoBomLf (Join-Path $NegRoot "verify.stdout.txt") $r4.StdOut
Write-Utf8NoBomLf (Join-Path $NegRoot "verify.stderr.txt") $r4.StdErr

if($r4.ExitCode -eq 0){
  throw "NEG_SIG_FAIL:VERIFY_UNEXPECTED_SUCCESS"
}

if($r4.Text -notmatch 'COURIER_VERIFY_FAIL:UNTRUSTED_SIGNER' -and $r4.Text -notmatch 'No matching principal'){
  throw ("NEG_SIG_FAIL:WRONG_FAILURE_TOKEN:`n" + $r4.Text)
}

Write-Host "COURIER_NEGATIVE_UNTRUSTED_SIGNER_OK"