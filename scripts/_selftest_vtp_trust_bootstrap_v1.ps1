param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Export = Join-Path $PSScriptRoot "vtp_identity_invite_export_v1.ps1"
$Import = Join-Path $PSScriptRoot "vtp_identity_invite_import_v1.ps1"
$Pin    = Join-Path $PSScriptRoot "vtp_trust_pin_node_v1.ps1"

$trustRoot = Join-Path $RepoRoot "proofs\trust"
$keyRoot = Join-Path $RepoRoot "proofs\keys\vtp_invite_selftest"
if(Test-Path -LiteralPath $keyRoot){ Remove-Item -LiteralPath $keyRoot -Recurse -Force }
[void][System.IO.Directory]::CreateDirectory($keyRoot)

$keyPath = Join-Path $keyRoot "selftest_ed25519"
$pubPath = $keyPath + ".pub"
$ssh = $(if($env:WINDIR -and (Test-Path -LiteralPath (Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe"))){ Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe" } else { $c = Get-Command ssh-keygen -ErrorAction SilentlyContinue; if($null -eq $c){ throw "COURIER_FAIL:SSH_KEYGEN_NOT_FOUND" }; $c.Source })
$p = Start-Process -FilePath $ssh `
  -ArgumentList ('-t ed25519 -N "" -f "{0}" -C "vtp-selftest@local"' -f $keyPath) `
  -NoNewWindow `
  -Wait `
  -PassThru

if($p.ExitCode -ne 0){ throw "VTP_TRUST_BOOTSTRAP_SELFTEST_FAIL:KEYGEN" }

$inviteRoot = Join-Path $RepoRoot "test_vectors\vtp_trust_bootstrap\invite"
try {
  & $Export -RepoRoot $RepoRoot -NodeId "node-selftest" -Principal "vtp-selftest@local" -PublicKeyPath $pubPath -OutRoot $inviteRoot
}
catch {
  throw ("VTP_TRUST_BOOTSTRAP_SELFTEST_FAIL:EXPORT:" + $_.ToString())
}

try {
  & $Import -RepoRoot $RepoRoot -InviteRoot $inviteRoot
}
catch {
  throw ("VTP_TRUST_BOOTSTRAP_SELFTEST_FAIL:IMPORT:" + $_.ToString())
}

$invite = Get-Content -LiteralPath (Join-Path $inviteRoot "vtp_identity_invite.json") -Raw | ConvertFrom-Json

try {
  & $Pin -RepoRoot $RepoRoot -InviteRoot $inviteRoot -ExpectedFingerprintSha256 ([string]$invite.public_key_sha256)
}
catch {
  throw ("VTP_TRUST_BOOTSTRAP_SELFTEST_FAIL:PIN:" + $_.ToString())
}

Write-Host "VTP_TRUST_BOOTSTRAP_SELFTEST_OK"
