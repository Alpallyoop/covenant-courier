param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

# VTP identity invite export -> import -> pin, in a sandbox root (never this repository's trust roots):
# the pin line is namespaced to courier/message, the fingerprint is computed from the key, a re-pin of
# the same key is a no-op, and a wrong fingerprint, a forged invite fingerprint, a principal with
# pattern or line characters, and a second key for a pinned principal are refused.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Export = Join-Path $PSScriptRoot "vtp_identity_invite_export_v1.ps1"
$Import = Join-Path $PSScriptRoot "vtp_identity_invite_import_v1.ps1"
$Pin    = Join-Path $PSScriptRoot "vtp_trust_pin_node_v1.ps1"
function Must([bool]$c,[string]$code){ if(-not $c){ throw ("VTP_TRUST_BOOTSTRAP_SELFTEST_FAIL:" + $code) } }

$RepoRoot = (Resolve-Path $RepoRoot).Path
$Sandbox = Join-Path $RepoRoot ("runtime\selftest_vtp_trust\" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ"))
[void][System.IO.Directory]::CreateDirectory($Sandbox)
$ssh = $(if($env:WINDIR -and (Test-Path -LiteralPath (Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe"))){ Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe" } else { $c = Get-Command ssh-keygen -ErrorAction SilentlyContinue; if($null -eq $c){ throw "COURIER_FAIL:SSH_KEYGEN_NOT_FOUND" }; $c.Source })
function NewKey([string]$Name){
  $k = Join-Path $Sandbox ("keys\" + $Name)
  [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $k))
  $p = Start-Process -FilePath $ssh -ArgumentList ('-q -t ed25519 -N "" -f "{0}" -C "vtp-selftest"' -f $k) -NoNewWindow -Wait -PassThru
  Must ($p.ExitCode -eq 0) "KEYGEN"
  return ($k + ".pub")
}
function Refused([scriptblock]$B,[string]$Token){
  try { & $B; return $false } catch { return ($_.ToString() -match [regex]::Escape($Token)) }
}

$pub1 = NewKey "one_ed25519"
$inv1 = Join-Path $Sandbox "invite1"
& $Export -RepoRoot $Sandbox -NodeId "node-selftest" -Principal "vtp-selftest@local" -PublicKeyPath $pub1 -OutRoot $inv1
& $Import -RepoRoot $Sandbox -InviteRoot $inv1
$invite = Get-Content -LiteralPath (Join-Path $inv1 "vtp_identity_invite.json") -Raw | ConvertFrom-Json
$fp = [string]$invite.public_key_sha256

Must (Refused { & $Pin -RepoRoot $Sandbox -InviteRoot $inv1 -ExpectedFingerprintSha256 ("0" * 64) } "FINGERPRINT_MISMATCH") "WRONG_FP"
& $Pin -RepoRoot $Sandbox -InviteRoot $inv1 -ExpectedFingerprintSha256 $fp
& $Pin -RepoRoot $Sandbox -InviteRoot $inv1 -ExpectedFingerprintSha256 $fp
$allowed = @([IO.File]::ReadAllLines((Join-Path $Sandbox "proofs\trust\allowed_signers")))
Must ($allowed.Count -eq 1 -and $allowed[0] -cmatch '^vtp-selftest@local namespaces="courier/message" ssh-ed25519 [A-Za-z0-9+/=]+\z') ("PIN_LINE:" + ($allowed -join "|"))
Write-Host "VTP_TRUST_BOOTSTRAP_CASE_OK: pin is namespaced, fingerprint computed from the key, re-pin is a no-op"

# A forged invite: the claimed fingerprint is another key's, or the principal carries a pattern or newline.
$pub2 = NewKey "two_ed25519"
$inv2 = Join-Path $Sandbox "invite2"
& $Export -RepoRoot $Sandbox -NodeId "node-two" -Principal "vtp-selftest@local" -PublicKeyPath $pub2 -OutRoot $inv2
$j = Get-Content -LiteralPath (Join-Path $inv2 "vtp_identity_invite.json") -Raw | ConvertFrom-Json
$fp2 = [string]$j.public_key_sha256
Must (Refused { & $Pin -RepoRoot $Sandbox -InviteRoot $inv2 -ExpectedFingerprintSha256 $fp2 } "PRINCIPAL_ALREADY_PINNED") "SECOND_KEY_SAME_PRINCIPAL"
$j.public_key_sha256 = $fp
[IO.File]::WriteAllText((Join-Path $inv2 "vtp_identity_invite.json"),($j | ConvertTo-Json -Compress))
Must (Refused { & $Pin -RepoRoot $Sandbox -InviteRoot $inv2 -ExpectedFingerprintSha256 $fp } "FINGERPRINT_MISMATCH") "CLAIMED_FP_NOT_TRUSTED"
foreach($bad in @("*","evil`nx ssh-ed25519 AAAA","a b",'x" -f "y')){
  $j.principal = $bad; $j.public_key_sha256 = $fp2
  [IO.File]::WriteAllText((Join-Path $inv2 "vtp_identity_invite.json"),($j | ConvertTo-Json -Compress))
  Must (Refused { & $Pin -RepoRoot $Sandbox -InviteRoot $inv2 -ExpectedFingerprintSha256 $fp2 } "BAD_PRINCIPAL") ("BAD_PRINCIPAL:" + $bad)
}
$j.principal = "vtp-two@local"; $j.public_key = ([string]$j.public_key) + "`ncert-authority ssh-ed25519 AAAA"
[IO.File]::WriteAllText((Join-Path $inv2 "vtp_identity_invite.json"),($j | ConvertTo-Json -Compress))
Must (Refused { & $Pin -RepoRoot $Sandbox -InviteRoot $inv2 -ExpectedFingerprintSha256 $fp2 } "BAD_PUBLIC_KEY") "BAD_KEY"
Must (@([IO.File]::ReadAllLines((Join-Path $Sandbox "proofs\trust\allowed_signers"))).Count -eq 1) "NOTHING_ELSE_PINNED"
Write-Host "VTP_TRUST_BOOTSTRAP_CASE_OK: wrong or claimed fingerprint, pattern/newline principal, extra key line, second key -> refused"

Remove-Item -LiteralPath (Join-Path $Sandbox "keys") -Recurse -Force
Write-Host "VTP_TRUST_BOOTSTRAP_SELFTEST_OK"
