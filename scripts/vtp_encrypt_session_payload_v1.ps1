param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$PlainPath,
  [Parameter(Mandatory=$true)][string]$JoinCode,
  [Parameter(Mandatory=$true)][string]$SessionId,
  [Parameter(Mandatory=$true)][string]$FromNodeId,
  [Parameter(Mandatory=$true)][string]$ToNodeId,
  [Parameter(Mandatory=$true)][string]$OutPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\_lib_vtp_session_v1.ps1"

if(-not (Test-Path -LiteralPath $PlainPath -PathType Leaf)){
  throw "VTP_SESSION_ENCRYPT_FAIL:MISSING_PLAIN"
}

$salt = New-RandomBytes 16
$iv = New-RandomBytes 16
$key = Get-VtpSessionKeyMaterial -JoinCode $JoinCode -SessionId $SessionId -Salt $salt

$plain = [System.IO.File]::ReadAllBytes($PlainPath)
$aadText = "vtp.session.payload.v1|" + $SessionId + "|" + $FromNodeId + "|" + $ToNodeId
$aad = [System.Text.Encoding]::UTF8.GetBytes($aadText)

$result = Protect-BytesAesCbcHmacSha256 $plain $key $iv $aad

$obj = [ordered]@{
  schema = "vtp.session_encrypted_payload.v1"
  created_utc = (Get-Date).ToUniversalTime().ToString("o")
  cipher = "AES-256-CBC-HMAC-SHA256"
  kdf = "PBKDF2-HMAC-SHA256-200000"
  session_id = $SessionId
  from_node_id = $FromNodeId
  to_node_id = $ToNodeId
  aad = $aadText
  salt_b64 = [Convert]::ToBase64String($salt)
  iv_b64 = [Convert]::ToBase64String($iv)
  tag_b64 = [Convert]::ToBase64String($result.tag)
  ciphertext_b64 = [Convert]::ToBase64String($result.cipher)
}

Write-Utf8NoBomLf $OutPath (($obj | ConvertTo-Json -Depth 20 -Compress))
Write-Host ("VTP_SESSION_ENCRYPTED_PAYLOAD: " + $OutPath)
Write-Host "VTP_SESSION_ENCRYPT_OK"
