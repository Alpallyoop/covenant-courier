param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$InviteRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedFingerprintSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$Code){ throw $Code }
function Ensure-Dir([string]$Path){ if(-not (Test-Path -LiteralPath $Path)){ [void][System.IO.Directory]::CreateDirectory($Path) } }
function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir){ Ensure-Dir $dir }
  $t = ($Text -replace "`r`n","`n") -replace "`r","`n"
  if(-not $t.EndsWith("`n")){ $t += "`n" }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path,$t,$enc)
}
function Append-Utf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir){ Ensure-Dir $dir }
  $t = ($Text -replace "`r`n","`n") -replace "`r","`n"
  if(-not $t.EndsWith("`n")){ $t += "`n" }
  $enc = New-Object System.Text.UTF8Encoding($false)
  $fs = [System.IO.File]::Open($Path,[System.IO.FileMode]::Append,[System.IO.FileAccess]::Write,[System.IO.FileShare]::Read)
  try { $b=$enc.GetBytes($t); $fs.Write($b,0,$b.Length); $fs.Flush() } finally { $fs.Dispose() }
}

$invitePath = Join-Path $InviteRoot "vtp_identity_invite.json"
if(-not (Test-Path -LiteralPath $invitePath -PathType Leaf)){ Fail "VTP_TRUST_PIN_FAIL:MISSING_INVITE" }

if((Get-Item -LiteralPath $invitePath).Length -gt 65536){ Fail "VTP_TRUST_PIN_FAIL:INVITE_TOO_LARGE" }
$invite = Get-Content -LiteralPath $invitePath -Raw | ConvertFrom-Json
if($ExpectedFingerprintSha256 -cnotmatch '^[0-9a-f]{64}\z'){ Fail "VTP_TRUST_PIN_FAIL:BAD_EXPECTED_FINGERPRINT" }

# Everything written to allowed_signers is checked here: one ed25519 key, a principal with no pattern,
# option or line characters, and a node id. The fingerprint is computed from the key itself (the same
# bytes the invite export hashed), never taken from the invite's own claim.
$nodeId = [string]$invite.node_id
$principal = [string]$invite.principal
$pub = ([string]$invite.public_key).Trim()
if($nodeId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,71}\z' -or $nodeId.Contains("..")){ Fail "VTP_TRUST_PIN_FAIL:BAD_NODE_ID" }
if($principal -cnotmatch '^[A-Za-z0-9][A-Za-z0-9@._/+-]{0,199}\z'){ Fail "VTP_TRUST_PIN_FAIL:BAD_PRINCIPAL" }
$m = [regex]::Match($pub,'^(ssh-ed25519) ([A-Za-z0-9+/]+={0,2})(?: [A-Za-z0-9@._/+:-]{0,200})?\z')
if(-not $m.Success){ Fail "VTP_TRUST_PIN_FAIL:BAD_PUBLIC_KEY" }
try { $blob = [Convert]::FromBase64String($m.Groups[2].Value) } catch { Fail "VTP_TRUST_PIN_FAIL:BAD_PUBLIC_KEY" }
if($blob.Length -ne 51){ Fail "VTP_TRUST_PIN_FAIL:BAD_PUBLIC_KEY" }
$sha = [System.Security.Cryptography.SHA256]::Create()
try { $actual = (($sha.ComputeHash((New-Object System.Text.UTF8Encoding($false)).GetBytes($pub + "`n")) | ForEach-Object { $_.ToString("x2") }) -join "") } finally { $sha.Dispose() }
if($actual -cne $ExpectedFingerprintSha256){
  Fail ("VTP_TRUST_PIN_FAIL:FINGERPRINT_MISMATCH:EXPECTED=" + $ExpectedFingerprintSha256 + ":ACTUAL=" + $actual)
}
if([string]$invite.public_key_sha256 -cne $actual){ Fail "VTP_TRUST_PIN_FAIL:INVITE_FINGERPRINT_WRONG" }

$trustRoot = Join-Path $RepoRoot "proofs\trust"
Ensure-Dir $trustRoot

$allowed = Join-Path $trustRoot "allowed_signers"
$keyCore = $m.Groups[1].Value + " " + $m.Groups[2].Value
$line = $principal + ' namespaces="courier/message" ' + $keyCore
# A principal is pinned once: the same pin again is a no-op, a different key for it is refused (a new key
# for a known principal is a rotation, done by removing the old line on purpose).
$already = $false
if(Test-Path -LiteralPath $allowed -PathType Leaf){
  foreach($l in [System.IO.File]::ReadAllLines($allowed)){
    $f = @($l.Trim() -split '\s+')
    if($f.Count -lt 2 -or $f[0] -cne $principal){ continue }
    if($l.Trim() -ceq $line){ $already = $true; continue }
    Fail "VTP_TRUST_PIN_FAIL:PRINCIPAL_ALREADY_PINNED"
  }
}
if(-not $already){ Append-Utf8NoBomLf $allowed $line }

$receiptRoot = Join-Path $RepoRoot "proofs\receipts"
Ensure-Dir $receiptRoot
$receipt = [ordered]@{
  schema = "vtp.trust_pin.receipt.v1"
  event_type = "vtp.trust.pin_node.v1"
  timestamp_utc = (Get-Date).ToUniversalTime().ToString("o")
  details = [ordered]@{
    node_id = $nodeId
    principal = $principal
    public_key_sha256 = $actual
    allowed_signers = $allowed
  }
}
Append-Utf8NoBomLf (Join-Path $receiptRoot "vtp_trust.ndjson") (($receipt | ConvertTo-Json -Depth 20 -Compress))

Write-Host ("VTP_TRUST_PINNED_NODE: " + $nodeId)
Write-Host ("VTP_TRUST_PINNED_PRINCIPAL: " + $principal)
Write-Host "VTP_TRUST_PIN_NODE_OK"
