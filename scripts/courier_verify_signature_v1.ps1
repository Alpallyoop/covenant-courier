param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$MessagePath,
  [Parameter(Mandatory=$true)][string]$SignerIdentity,
  [string]$Namespace = "courier/message",
  # Also trust the published release signers (trust/allowed_signers): only for verifying the public test
  # vectors, never for runtime frames or documents.
  [switch]$IncludeReleaseSigners
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$Code){
  throw $Code
}

# Trust roots: the signer created by this machine's local trust bootstrap (proofs/, never committed)
# and signers imported from a pinned NeverLost trust bundle (courier_trust_import_neverlost_v1.ps1).
# The published release signers (trust/allowed_signers, tracked) sign the public test vectors; they are
# a trust root only with -IncludeReleaseSigners, so a public signed vector can never be framed and
# accepted as a runtime message. Every other case fails closed.
$AllowedCandidates = @(
  $(if($IncludeReleaseSigners){ Join-Path $RepoRoot "trust\allowed_signers" }),
  (Join-Path $RepoRoot "proofs\trust\allowed_signers"),
  (Join-Path $RepoRoot "proofs\trust\neverlost\allowed_signers")
) | Where-Object { $null -ne $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) }
$SSHKeygen = $(if($env:WINDIR -and (Test-Path -LiteralPath (Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe"))){ Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe" } else { $c = Get-Command ssh-keygen -ErrorAction SilentlyContinue; if($null -eq $c){ throw "COURIER_FAIL:SSH_KEYGEN_NOT_FOUND" }; $c.Source })

if(-not (Test-Path -LiteralPath $SSHKeygen)){
  Fail ("COURIER_VERIFY_FAIL:MISSING_SSH_KEYGEN:" + $SSHKeygen)
}
if(@($AllowedCandidates).Count -lt 1){
  Fail "COURIER_VERIFY_FAIL:ALLOWED_SIGNERS_MISSING"
}
# Identity and namespace go into ssh-keygen's argument string: refuse anything that could break out of
# it or act as an allowed_signers pattern.
if($SignerIdentity -cnotmatch '^[A-Za-z0-9@._/:+-]{1,200}\z'){ Fail "COURIER_VERIFY_FAIL:BAD_SIGNER_IDENTITY" }
if($Namespace -cnotmatch '^[A-Za-z0-9._/-]{1,100}\z'){ Fail "COURIER_VERIFY_FAIL:BAD_NAMESPACE" }
if(-not (Test-Path -LiteralPath $MessagePath -PathType Leaf)){
  Fail "COURIER_VERIFY_FAIL:MISSING_MESSAGE"
}
if(-not (Test-Path -LiteralPath ($MessagePath + ".sig") -PathType Leaf)){
  Fail "COURIER_VERIFY_FAIL:MISSING_SIGNATURE"
}
foreach($f in @($MessagePath,($MessagePath + ".sig"))){
  $fi = Get-Item -LiteralPath $f -Force
  if(($fi.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){ Fail "COURIER_VERIFY_FAIL:LINK_NOT_ALLOWED" }
  if($fi.Length -gt 4MB){ Fail "COURIER_VERIFY_FAIL:INPUT_TOO_LARGE" }
}

# Read the message and signature once and verify exactly those bytes from a private staging folder with a
# GUID name (no later re-read of the caller's file, no path the caller chose reaches ssh-keygen or cmd).
$MessageBytes = [System.IO.File]::ReadAllBytes($MessagePath)
$SigBytes = [System.IO.File]::ReadAllBytes($MessagePath + ".sig")
$StageDir = Join-Path $RepoRoot ("runtime\tmp\verify-" + [guid]::NewGuid().ToString("N"))
[void][System.IO.Directory]::CreateDirectory($StageDir)
$StageMsg = Join-Path $StageDir "message"
$SigPath = $StageMsg + ".sig"
[System.IO.File]::WriteAllBytes($StageMsg,$MessageBytes)
[System.IO.File]::WriteAllBytes($SigPath,$SigBytes)
foreach($v in @($StageMsg) + @($AllowedCandidates)){ if($v -match '["%^&|<>!]'){ Fail "COURIER_VERIFY_FAIL:UNSAFE_PATH" } }

function Invoke-SshVerify([string]$AllowedPath){
  $sshArgs = ('-Y verify -f "{0}" -I "{1}" -n "{2}" -s "{3}"' -f $AllowedPath, $SignerIdentity, $Namespace, $SigPath)
  if($PSVersionTable.PSVersion.Major -lt 6 -and $env:ComSpec){
    # Windows PowerShell 5.1 (.NET Framework): a redirected stdin is a StreamWriter that writes the
    # console input encoding's preamble (a UTF-8 BOM when the console code page is 65001) before any
    # message byte, so the signed bytes no longer match. Let cmd feed the staged file to ssh-keygen; the
    # staged path is ours (GUID name) and was checked above for characters cmd would interpret.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec
    $psi.Arguments = ('/d /s /c ""{0}" {1} < "{2}""' -f $SSHKeygen, $sshArgs, $StageMsg)
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
    return [pscustomobject]@{ ExitCode = $p.ExitCode; Message = ($stdout + "`n" + $stderr).Trim() }
  }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $SSHKeygen
  $psi.Arguments = $sshArgs
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput  = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.CreateNoWindow = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()

  $stdin = $p.StandardInput.BaseStream
  $stdin.Write($MessageBytes, 0, $MessageBytes.Length)
  $stdin.Flush()
  $stdin.Close()

  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  return [pscustomobject]@{ ExitCode = $p.ExitCode; Message = ($stdout + "`n" + $stderr).Trim() }
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

$last = $null
try {
  foreach($candidate in @($AllowedCandidates)){
    $last = Invoke-SshVerify $candidate
    if($last.ExitCode -eq 0){ break }
  }
  if($null -eq $last -or $last.ExitCode -ne 0){
    $owners = @()
    foreach($candidate in @($AllowedCandidates)){ $owners += @(Get-SignaturePrincipals $candidate) }
    if(@($owners) -notcontains $SignerIdentity){
      Fail ("COURIER_VERIFY_FAIL:UNTRUSTED_SIGNER:" + $SignerIdentity)
    }
    $code = $(if($null -eq $last){ 255 } else { $last.ExitCode })
    $msg = $(if($null -eq $last){ "" } else { $last.Message })
    if($msg.Length -gt 0){ Fail ("COURIER_VERIFY_FAIL:SIG_VERIFY_FAIL:SSH_VERIFY_EXIT_" + $code + ":" + $msg) }
    Fail ("COURIER_VERIFY_FAIL:SIG_VERIFY_FAIL:SSH_VERIFY_EXIT_" + $code)
  }
} finally {
  Remove-Item -LiteralPath $StageDir -Recurse -Force -ErrorAction SilentlyContinue
}

$sha = [Security.Cryptography.SHA256]::Create()
try { $verifiedHash = (($sha.ComputeHash($MessageBytes) | ForEach-Object { $_.ToString("x2") }) -join "") } finally { $sha.Dispose() }
Write-Host ("COURIER_SIGNATURE_VERIFIED_SHA256: " + $verifiedHash)
Write-Host "COURIER_SIGNATURE_VERIFY_OK"
exit 0
