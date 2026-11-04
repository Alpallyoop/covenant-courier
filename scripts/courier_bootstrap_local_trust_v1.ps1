param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [string]$SignerIdentity = "courier-local@covenant"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\_lib_courier_v1.ps1"

function Fail([string]$Code){
  throw $Code
}

$SSHKeygen = $(if($env:WINDIR -and (Test-Path -LiteralPath (Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe"))){ Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe" } else { $c = Get-Command ssh-keygen -ErrorAction SilentlyContinue; if($null -eq $c){ throw "COURIER_FAIL:SSH_KEYGEN_NOT_FOUND" }; $c.Source })
if(-not (Test-Path -LiteralPath $SSHKeygen)){
  Fail ("TRUST_FAIL:MISSING_SSH_KEYGEN:" + $SSHKeygen)
}

$KeysDir  = Join-Path $RepoRoot "proofs\keys"
$TrustDir = Join-Path $RepoRoot "proofs\trust"

Ensure-Dir $KeysDir
Ensure-Dir $TrustDir

# The identity goes into ssh-keygen arguments and allowed_signers: no quotes, spaces or pattern characters.
if($SignerIdentity -cnotmatch '^[A-Za-z0-9][A-Za-z0-9@._/+-]{0,199}\z'){ Fail "TRUST_FAIL:BAD_SIGNER_IDENTITY" }
$SafeId = ($SignerIdentity -replace '[^A-Za-z0-9._-]','_')
$PrivKey = Join-Path $KeysDir ("courier_" + $SafeId + "_ed25519")
$PubKey  = $PrivKey + ".pub"
$Allowed = Join-Path $TrustDir "allowed_signers"
$Bundle  = Join-Path $TrustDir "trust_bundle.json"

if(-not (Test-Path -LiteralPath $PrivKey)){
  $argsString = ('-q -t ed25519 -N "" -C "{0}" -f "{1}"' -f $SignerIdentity, $PrivKey)

  if([string]::IsNullOrWhiteSpace($argsString)){
    Fail "TRUST_FAIL:EMPTY_ARGSTRING"
  }

  $proc = Start-Process `
    -FilePath $SSHKeygen `
    -ArgumentList $argsString `
    -Wait `
    -PassThru `
    -NoNewWindow

  if($proc.ExitCode -ne 0){
    Fail ("TRUST_FAIL:KEYGEN_EXIT_" + $proc.ExitCode)
  }
}

if(-not (Test-Path -LiteralPath $PubKey)){
  Fail "TRUST_FAIL:MISSING_PUBKEY_AFTER_KEYGEN"
}

$pub = (Get-Content -Raw -LiteralPath $PubKey).Trim()

$pm = [regex]::Match($pub,'^(ssh-ed25519 [A-Za-z0-9+/]+={0,2})(?: .*)?\z')
if(-not $pm.Success){ Fail "TRUST_FAIL:BAD_PUBLIC_KEY" }
# This signer's line, valid for courier messages only (not Covenant Gate decisions or any other
# namespace). Other principals' lines (pinned peers) are kept as they are.
$myLine = $SignerIdentity + ' namespaces="courier/message" ' + $pm.Groups[1].Value
$keep = New-Object System.Collections.Generic.List[string]
if(Test-Path -LiteralPath $Allowed -PathType Leaf){
  foreach($l in [System.IO.File]::ReadAllLines($Allowed)){
    if([string]::IsNullOrWhiteSpace($l)){ continue }
    if(@($l.Trim() -split '\s+')[0] -ceq $SignerIdentity){ continue }
    $keep.Add($l.TrimEnd())
  }
}
$keep.Add($myLine)
Write-Utf8NoBomLf $Allowed (($keep.ToArray()) -join "`n")

$bundleObj = [ordered]@{
  schema = "courier.trust_bundle.v1"
  signer_identities = @(
    [ordered]@{
      identity = $SignerIdentity
      public_key_path = ("proofs/keys/" + [System.IO.Path]::GetFileName($PubKey))
      allowed_signers_path = "proofs/trust/allowed_signers"
    }
  )
}

Write-JsonCanonical $Bundle $bundleObj

Append-Receipt $RepoRoot ([ordered]@{
  schema        = "courier.receipt.v1"
  event_type    = "courier.local_trust.bootstrapped.v1"
  timestamp_utc = [DateTime]::UtcNow.ToString("o")
  details       = [ordered]@{
    signer_identity     = $SignerIdentity
    private_key_rel     = ("proofs/keys/" + [System.IO.Path]::GetFileName($PrivKey))
    public_key_rel      = ("proofs/keys/" + [System.IO.Path]::GetFileName($PubKey))
    allowed_signers_rel = "proofs/trust/allowed_signers"
    trust_bundle_rel    = "proofs/trust/trust_bundle.json"
  }
})

Write-Host "COURIER_LOCAL_TRUST_BOOTSTRAP_OK"
