param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$InviteRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$Code){ throw $Code }
function Get-Sha256Hex([string]$Path){
  $sha=[System.Security.Cryptography.SHA256]::Create()
  $fs=[System.IO.File]::OpenRead($Path)
  try{ $h=$sha.ComputeHash($fs) } finally { $fs.Dispose(); $sha.Dispose() }
  return (($h | ForEach-Object { $_.ToString("x2") }) -join "")
}

$shaPath = Join-Path $InviteRoot "sha256sums.txt"
if(-not (Test-Path -LiteralPath $shaPath -PathType Leaf)){ Fail "VTP_INVITE_IMPORT_FAIL:MISSING_SHA256SUMS" }

foreach($line in @(Get-Content -LiteralPath $shaPath)){
  if([string]::IsNullOrWhiteSpace($line)){ continue }
  if($line -notmatch '^([0-9a-f]{64})\s{2}(.+)$'){ Fail ("VTP_INVITE_IMPORT_FAIL:BAD_SHA_LINE:" + $line) }
  $expected=$matches[1]; $rel=$matches[2]
  # A listed file is a plain name inside the invite folder.
  if($rel -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z' -or $rel.Contains("..")){ Fail "VTP_INVITE_IMPORT_FAIL:BAD_FILE_NAME" }
  $path=Join-Path $InviteRoot $rel
  if(-not (Test-Path -LiteralPath $path -PathType Leaf)){ Fail ("VTP_INVITE_IMPORT_FAIL:MISSING_HASHED_FILE:" + $rel) }
  $actual=Get-Sha256Hex $path
  if($actual -ne $expected){ Fail ("VTP_INVITE_IMPORT_FAIL:HASH_MISMATCH:" + $rel) }
}

$invitePath = Join-Path $InviteRoot "vtp_identity_invite.json"
if(-not (Test-Path -LiteralPath $invitePath -PathType Leaf)){ Fail "VTP_INVITE_IMPORT_FAIL:MISSING_INVITE" }

$invite = Get-Content -LiteralPath $invitePath -Raw | ConvertFrom-Json
Write-Host ("VTP_INVITE_NODE_ID: " + [string]$invite.node_id)
Write-Host ("VTP_INVITE_PRINCIPAL: " + [string]$invite.principal)
Write-Host ("VTP_INVITE_FINGERPRINT_SHA256: " + [string]$invite.public_key_sha256)
Write-Host "VTP_IDENTITY_INVITE_IMPORT_OK"
Write-Host "VERIFY_FINGERPRINT_OUT_OF_BAND_BEFORE_PINNING"
