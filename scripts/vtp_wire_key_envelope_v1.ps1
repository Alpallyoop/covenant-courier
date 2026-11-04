param(
  [string]$RepoRoot = ".",
  [string]$SessionId = "session-alpha-beta-001",
  [string]$SenderNodeId = "node-alpha",
  [string]$RecipientNodeId = "node-beta"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-VtpWireKeyEnvelopePath {
  param(
    [Parameter(Mandatory=$true)][string]$RepoRoot,
    [string]$SessionId = "session-alpha-beta-001",
    [string]$SenderNodeId = "node-alpha",
    [string]$RecipientNodeId = "node-beta"
  )
  $root = (Resolve-Path $RepoRoot).Path
  $dir = Join-Path $root "runtime\wire_keys"
  if(-not (Test-Path -LiteralPath $dir)){ [void][IO.Directory]::CreateDirectory($dir) }
  foreach($id in @($SessionId,$SenderNodeId,$RecipientNodeId)){ if($id -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z' -or $id.Contains("..")){ throw "VTP_WIRE_KEY_FAIL:BAD_ID" } }
  $safe = ($SessionId + "." + $SenderNodeId + "." + $RecipientNodeId)
  return (Join-Path $dir ($safe + ".keyenv.json"))
}

function Protect-VtpWireKeyFile([string]$Path){
  if($env:OS -eq "Windows_NT"){
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true,$false)
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.SetOwner($me)
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($me,"FullControl","Allow")))
    Set-Acl -LiteralPath $Path -AclObject $acl
  } else {
    & chmod 600 $Path
    if($LASTEXITCODE -ne 0){ throw "VTP_WIRE_KEY_FAIL:CHMOD" }
  }
}

function New-VtpRandomBytes {
  param([int]$Length)
  $bytes = New-Object byte[] $Length
  $rng = [Security.Cryptography.RNGCryptoServiceProvider]::new()
  try {
    $rng.GetBytes($bytes)
    return $bytes
  } finally {
    $rng.Dispose()
  }
}

function Ensure-VtpWireKeyEnvelope {
  param(
    [Parameter(Mandatory=$true)][string]$RepoRoot,
    [string]$SessionId = "session-alpha-beta-001",
    [string]$SenderNodeId = "node-alpha",
    [string]$RecipientNodeId = "node-beta"
  )
  $path = Get-VtpWireKeyEnvelopePath -RepoRoot $RepoRoot -SessionId $SessionId -SenderNodeId $SenderNodeId -RecipientNodeId $RecipientNodeId
  if(Test-Path -LiteralPath $path -PathType Leaf){
    return $path
  }
  $obj = [ordered]@{}
  $obj.schema = "vtp.wire_key_envelope.v1"
  $obj.created_utc = (Get-Date).ToUniversalTime().ToString("o")
  $obj.session_id = $SessionId
  $obj.sender_node_id = $SenderNodeId
  $obj.recipient_node_id = $RecipientNodeId
  $obj.key_scope = "local-dev-runtime"
  $obj.cipher_suite = "AES-CBC-256-HMAC-SHA256-DEV"
  $obj.aes_key_b64 = [Convert]::ToBase64String((New-VtpRandomBytes 32))
  $obj.hmac_key_b64 = [Convert]::ToBase64String((New-VtpRandomBytes 32))
  $json = $obj | ConvertTo-Json -Depth 20 -Compress
  # Key material: the file is created empty, made readable by this account only, then written.
  $fs = [IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  $fs.Dispose()
  Protect-VtpWireKeyFile $path
  [IO.File]::WriteAllText($path, ($json + [string][char]10), [Text.UTF8Encoding]::new($false))
  return $path
}

function Get-VtpWireKeyBytes {
  param(
    [Parameter(Mandatory=$true)][string]$RepoRoot,
    [Parameter(Mandatory=$true)][string]$RecipientNodeId,
    [Parameter(Mandatory=$true)][string]$Purpose,
    [string]$SessionId = "session-alpha-beta-001",
    [string]$SenderNodeId = "node-alpha"
  )
  $path = Ensure-VtpWireKeyEnvelope -RepoRoot $RepoRoot -SessionId $SessionId -SenderNodeId $SenderNodeId -RecipientNodeId $RecipientNodeId
  $env = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
  if([string]$env.schema -ne "vtp.wire_key_envelope.v1"){ throw "VTP_WIRE_KEY_FAIL:BAD_SCHEMA" }
  if($Purpose -eq "aes"){ return [Convert]::FromBase64String([string]$env.aes_key_b64) }
  if($Purpose -eq "hmac"){ return [Convert]::FromBase64String([string]$env.hmac_key_b64) }
  throw ("VTP_WIRE_KEY_FAIL:UNKNOWN_PURPOSE:" + $Purpose)
}

if($MyInvocation.InvocationName -ne "."){
  $RepoRoot = (Resolve-Path $RepoRoot).Path
  $path = Ensure-VtpWireKeyEnvelope -RepoRoot $RepoRoot -SessionId $SessionId -SenderNodeId $SenderNodeId -RecipientNodeId $RecipientNodeId
  Write-Host ("VTP_WIRE_KEY_ENVELOPE_OK: " + $path)
}
