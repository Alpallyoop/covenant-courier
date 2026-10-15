param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$PlainPath,
  [Parameter(Mandatory=$true)][string]$JoinCode,
  [Parameter(Mandatory=$true)][string]$Context,
  [Parameter(Mandatory=$true)][string]$OutPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_lib_vtp_crypto_v1.ps1"

if(-not (Test-Path -LiteralPath $PlainPath -PathType Leaf)){ throw "VTP_ENCRYPT_FAIL:MISSING_PLAIN" }

$salt = New-RandomBytes 16
$iv = New-RandomBytes 16
$key = Derive-KeyFromJoinCode $JoinCode $salt
$plain = [System.IO.File]::ReadAllBytes($PlainPath)
$aad = [System.Text.Encoding]::UTF8.GetBytes($Context)

$result = Protect-BytesAesCbcHmacSha256 $plain $key $iv $aad

$obj = [ordered]@{
  schema = "vtp.encrypted_payload.v1"
  created_utc = (Get-Date).ToUniversalTime().ToString("o")
  cipher = "AES-256-CBC-HMAC-SHA256"
  kdf = "PBKDF2-HMAC-SHA256-200000"
  context = $Context
  salt_b64 = [Convert]::ToBase64String($salt)
  iv_b64 = [Convert]::ToBase64String($iv)
  tag_b64 = [Convert]::ToBase64String($result.tag)
  ciphertext_b64 = [Convert]::ToBase64String($result.cipher)
}

Write-Utf8NoBomLf $OutPath (($obj | ConvertTo-Json -Depth 20 -Compress))
Write-Host ("VTP_ENCRYPTED_PAYLOAD: " + $OutPath)
Write-Host "VTP_ENCRYPT_PAYLOAD_OK"
