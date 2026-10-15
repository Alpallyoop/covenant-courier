# Session bindings for the VTP v1 UDP wire adapter.
#
# The wire header carries SHA-256 hashes of the session, sender node, recipient node and network
# IDs. These come from the session registry (registry/sessions/<id>.json), never from constants:
# the sender takes them from the session it is told to use, and the receiver finds the one open
# session whose ID hash matches and whose recipient is itself, then requires every other binding
# to match that session.

Set-StrictMode -Version Latest

function VtpWire-Sha256Text([string]$Text){
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return (($sha.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($Text)) | ForEach-Object { $_.ToString("x2") }) -join "") } finally { $sha.Dispose() }
}

function Get-VtpWireSession([string]$RepoRoot,[string]$SessionId,[string]$FailPrefix){
  if($SessionId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z' -or $SessionId.Contains('..')){ throw ($FailPrefix + ":BAD_SESSION_ID") }
  $path = Join-Path $RepoRoot ("registry\sessions\" + $SessionId + ".json")
  if(-not (Test-Path -LiteralPath $path -PathType Leaf)){ throw ($FailPrefix + ":UNKNOWN_SESSION") }
  $s = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
  if([string]$s.session_id -cne $SessionId){ throw ($FailPrefix + ":SESSION_REGISTRY_MISMATCH") }
  if([string]$s.status -cne "open"){ throw ($FailPrefix + ":SESSION_NOT_OPEN") }
  return $s
}

function Find-VtpWireSessionByHash([string]$RepoRoot,[string]$SessionIdHash,[string]$RecipientNodeId,[string]$FailPrefix){
  $dir = Join-Path $RepoRoot "registry\sessions"
  $found = @()
  foreach($f in @(Get-ChildItem -LiteralPath $dir -Filter "*.json" -File -ErrorAction SilentlyContinue)){
    $s = $null
    try { $s = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
    if((VtpWire-Sha256Text ([string]$s.session_id)) -ceq $SessionIdHash -and [string]$s.recipient_node_id -ceq $RecipientNodeId){ $found += ,$s }
  }
  if($found.Count -eq 0){ throw ($FailPrefix + ":UNKNOWN_SESSION") }
  if($found.Count -gt 1){ throw ($FailPrefix + ":AMBIGUOUS_SESSION") }
  if([string]$found[0].status -cne "open"){ throw ($FailPrefix + ":SESSION_NOT_OPEN") }
  return $found[0]
}
