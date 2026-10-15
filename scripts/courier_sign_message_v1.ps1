param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$MessagePath,
  [string]$SignerIdentity = "courier-local@covenant",
  [string]$Namespace = "courier/message"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\_lib_courier_v1.ps1"

function Fail([string]$Code){
  throw $Code
}

$SSHKeygen = $(if($env:WINDIR -and (Test-Path -LiteralPath (Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe"))){ Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe" } else { $c = Get-Command ssh-keygen -ErrorAction SilentlyContinue; if($null -eq $c){ throw "COURIER_FAIL:SSH_KEYGEN_NOT_FOUND" }; $c.Source })
if(-not (Test-Path -LiteralPath $SSHKeygen)){
  Fail ("SIGN_FAIL:MISSING_SSH_KEYGEN:" + $SSHKeygen)
}

if(-not (Test-Path -LiteralPath $MessagePath)){
  Fail ("SIGN_FAIL:MISSING_MESSAGE:" + $MessagePath)
}

$SafeId = ($SignerIdentity -replace '[^A-Za-z0-9._-]','_')
$PrivKey = Join-Path $RepoRoot ("proofs\keys\courier_" + $SafeId + "_ed25519")

if(-not (Test-Path -LiteralPath $PrivKey)){
  Fail ("SIGN_FAIL:MISSING_PRIVATE_KEY:" + $PrivKey)
}

$SigPath = $MessagePath + ".sig"

if(Test-Path -LiteralPath $SigPath){
  Remove-Item -LiteralPath $SigPath -Force
}

& $SSHKeygen -Y sign -f $PrivKey -n $Namespace $MessagePath | Out-Null
if($LASTEXITCODE -ne 0){
  Fail ("SIGN_FAIL:SIGN_EXIT_" + $LASTEXITCODE)
}

if(-not (Test-Path -LiteralPath $SigPath)){
  Fail "SIGN_FAIL:MISSING_SIGNATURE_OUTPUT"
}

Append-Receipt $RepoRoot ([ordered]@{
  schema        = "courier.receipt.v1"
  event_type    = "courier.message.signed.v1"
  timestamp_utc = [DateTime]::UtcNow.ToString("o")
  details       = [ordered]@{
    message_path    = $MessagePath
    signature_path  = $SigPath
    signer_identity = $SignerIdentity
    namespace       = $Namespace
    private_key_rel = ("proofs/keys/" + [System.IO.Path]::GetFileName($PrivKey))
  }
})

Write-Host ("COURIER_SIGN_OK: " + $SigPath)
