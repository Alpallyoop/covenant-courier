param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$EncryptedPath,
  [Parameter(Mandatory=$true)][string]$JoinCode,
  [Parameter(Mandatory=$true)][string]$OutPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_lib_vtp_crypto_v1.ps1"

if(-not (Test-Path -LiteralPath $EncryptedPath -PathType Leaf)){ throw "VTP_DECRYPT_FAIL:MISSING_ENCRYPTED" }

$obj = Get-Content -LiteralPath $EncryptedPath -Raw | ConvertFrom-Json
$salt = [Convert]::FromBase64String([string]$obj.salt_b64)
if([string]$obj.cipher -ne "AES-256-CBC-HMAC-SHA256"){ throw "VTP_DECRYPT_FAIL:UNSUPPORTED_CIPHER" }
$iv = [Convert]::FromBase64String([string]$obj.iv_b64)
$tag = [Convert]::FromBase64String([string]$obj.tag_b64)
$cipher = [Convert]::FromBase64String([string]$obj.ciphertext_b64)
$aad = [System.Text.Encoding]::UTF8.GetBytes([string]$obj.context)
$key = Derive-KeyFromJoinCode $JoinCode $salt

try {
  $plain = Unprotect-BytesAesCbcHmacSha256 $cipher $key $iv $tag $aad
}
catch {
  throw "VTP_DECRYPT_FAIL:AUTH_TAG_OR_JOIN_CODE_INVALID"
}

$dir = Split-Path -Parent $OutPath
if($dir){ Ensure-Dir $dir }
[System.IO.File]::WriteAllBytes($OutPath,$plain)
Write-Host ("VTP_DECRYPTED_PAYLOAD: " + $OutPath)
Write-Host "VTP_DECRYPT_PAYLOAD_OK"
