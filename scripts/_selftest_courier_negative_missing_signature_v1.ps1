param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PSExe = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$Scripts = Join-Path $RepoRoot "scripts"

$VerifySigScript = Join-Path $Scripts "courier_verify_signature_v1.ps1"
$Msg = Join-Path $RepoRoot "test_vectors\courier_v1\positive\msg.enc.json"
$Sig = $Msg + ".sig"

foreach($req in @($PSExe,$VerifySigScript,$Msg)){
  if(-not (Test-Path -LiteralPath $req)){
    throw ("NEG_SIG_FAIL:MISSING_REQUIRED:" + $req)
  }
}

if(Test-Path -LiteralPath $Sig){
  Remove-Item -LiteralPath $Sig -Force
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $PSExe
$psi.Arguments = (
  '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RepoRoot "{1}" -MessagePath "{2}" -SignerIdentity "courier-local@covenant"' -f
  $VerifySigScript, $RepoRoot, $Msg
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

$text = $stdout + "`n" + $stderr

if($proc.ExitCode -eq 0){
  throw "NEG_SIG_FAIL:VERIFY_UNEXPECTED_SUCCESS"
}
if($text -notmatch 'COURIER_VERIFY_FAIL:MISSING_SIGNATURE'){
  throw ("NEG_SIG_FAIL:WRONG_FAILURE_TOKEN:`n" + $text)
}

Write-Host "COURIER_NEGATIVE_MISSING_SIGNATURE_OK"