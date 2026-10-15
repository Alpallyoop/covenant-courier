param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$MessagePath,
  [Parameter(Mandatory=$true)][string]$SignerIdentity,
  [string]$Namespace = "courier/message"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$Code){
  throw $Code
}

# Trust roots, in order: the published release signers (tracked), the signer created by this
# machine's local trust bootstrap (proofs/, never committed) and signers imported from a pinned
# NeverLost trust bundle (courier_trust_import_neverlost_v1.ps1). A signature is accepted
# when it verifies against either; every other case fails closed.
$AllowedCandidates = @(
  (Join-Path $RepoRoot "trust\allowed_signers"),
  (Join-Path $RepoRoot "proofs\trust\allowed_signers"),
  (Join-Path $RepoRoot "proofs\trust\neverlost\allowed_signers")
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
$Allowed = $(if(@($AllowedCandidates).Count -gt 0){ @($AllowedCandidates)[0] } else { Join-Path $RepoRoot "trust\allowed_signers" })
$SigPath = $MessagePath + ".sig"
$SSHKeygen = $(if($env:WINDIR -and (Test-Path -LiteralPath (Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe"))){ Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe" } else { $c = Get-Command ssh-keygen -ErrorAction SilentlyContinue; if($null -eq $c){ throw "COURIER_FAIL:SSH_KEYGEN_NOT_FOUND" }; $c.Source })

if(-not (Test-Path -LiteralPath $SSHKeygen)){
  Fail ("COURIER_VERIFY_FAIL:MISSING_SSH_KEYGEN:" + $SSHKeygen)
}
if(-not (Test-Path -LiteralPath $Allowed)){
  Fail "COURIER_VERIFY_FAIL:ALLOWED_SIGNERS_MISSING"
}
if(-not (Test-Path -LiteralPath $MessagePath)){
  Fail "COURIER_VERIFY_FAIL:MISSING_MESSAGE"
}
if(-not (Test-Path -LiteralPath $SigPath)){
  Fail "COURIER_VERIFY_FAIL:MISSING_SIGNATURE"
}

function Invoke-SshVerify([string]$AllowedPath){
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $SSHKeygen
  $psi.Arguments = ('-Y verify -f "{0}" -I "{1}" -n "{2}" -s "{3}"' -f $AllowedPath, $SignerIdentity, $Namespace, $SigPath)
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput  = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.CreateNoWindow = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()

  $bytes = [System.IO.File]::ReadAllBytes($MessagePath)
  $stdin = $p.StandardInput.BaseStream
  $stdin.Write($bytes, 0, $bytes.Length)
  $stdin.Flush()
  $stdin.Close()

  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  return [pscustomobject]@{ ExitCode = $p.ExitCode; Message = ($stdout + "`n" + $stderr).Trim() }
}

$last = $null
foreach($candidate in @($AllowedCandidates)){
  $last = Invoke-SshVerify $candidate
  if($last.ExitCode -eq 0){ break }
}

function Get-SignaturePrincipals([string]$AllowedPath){
  # Which trusted principals (if any) own the key that made this signature. Needs no message bytes.
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $SSHKeygen
  $psi.Arguments = ('-Y find-principals -f "{0}" -s "{1}"' -f $AllowedPath, $SigPath)
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.CreateNoWindow = $true
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()
  $stdout = $p.StandardOutput.ReadToEnd()
  [void]$p.StandardError.ReadToEnd()
  $p.WaitForExit()
  if($p.ExitCode -ne 0){ return @() }
  return @($stdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
}

if($null -eq $last -or $last.ExitCode -ne 0){
  $owners = @()
  foreach($candidate in @($AllowedCandidates)){ $owners += @(Get-SignaturePrincipals $candidate) }
  if(@($owners) -notcontains $SignerIdentity){
    Fail ("COURIER_VERIFY_FAIL:UNTRUSTED_SIGNER:" + $SignerIdentity)
  }
  $code = $(if($null -eq $last){ 255 } else { $last.ExitCode })
  $msg = $(if($null -eq $last){ "" } else { $last.Message })
  if($msg.Length -gt 0){
    Fail ("COURIER_VERIFY_FAIL:SIG_VERIFY_FAIL:SSH_VERIFY_EXIT_" + $code + ":" + $msg)
  }
  else {
    Fail ("COURIER_VERIFY_FAIL:SIG_VERIFY_FAIL:SSH_VERIFY_EXIT_" + $code)
  }
}

Write-Host "COURIER_SIGNATURE_VERIFY_OK"
exit 0
