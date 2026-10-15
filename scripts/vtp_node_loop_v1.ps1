param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [string]$NodeId = "node-beta",
  [string]$ConfigPath = "",
  [switch]$Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Listen = Join-Path $PSScriptRoot "courier_transport_listen_v1.ps1"

function Ensure-Dir([string]$Path){
  if(-not (Test-Path -LiteralPath $Path)){
    [void][System.IO.Directory]::CreateDirectory($Path)
  }
}

function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir){ Ensure-Dir $dir }
  $t = ($Text -replace "`r`n","`n") -replace "`r","`n"
  if(-not $t.EndsWith("`n")){ $t += "`n" }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path,$t,$enc)
}

function Append-Receipt([string]$RepoRoot,[hashtable]$Details){
  $receiptRoot = Join-Path $RepoRoot "proofs\receipts"
  Ensure-Dir $receiptRoot
  $path = Join-Path $receiptRoot "vtp_node_loop.ndjson"

  $obj = [ordered]@{
    schema = "vtp.node_loop.receipt.v1"
    event_type = "vtp.node_loop.tick.v1"
    timestamp_utc = (Get-Date).ToUniversalTime().ToString("o")
    details = $Details
  }

  Add-Content -LiteralPath $path -Value ($obj | ConvertTo-Json -Depth 20 -Compress)
}

if([string]::IsNullOrWhiteSpace($ConfigPath)){
  $runtimeRoot = Join-Path $RepoRoot ("runtime\nodes\" + $NodeId)
  $drop = Join-Path $runtimeRoot "inbox\drop"
  $accepted = Join-Path $runtimeRoot "accepted"
  $rejected = Join-Path $runtimeRoot "rejected"
  $ConfigPath = Join-Path $runtimeRoot "listener.config.json"

  Ensure-Dir $drop
  Ensure-Dir $accepted
  Ensure-Dir $rejected

  $cfg = [ordered]@{
    drop_root = ($drop.Substring($RepoRoot.Length).TrimStart('\','/')).Replace('\','/')
    accepted_root = ($accepted.Substring($RepoRoot.Length).TrimStart('\','/')).Replace('\','/')
    rejected_root = ($rejected.Substring($RepoRoot.Length).TrimStart('\','/')).Replace('\','/')
  }

  Write-Utf8NoBomLf $ConfigPath (($cfg | ConvertTo-Json -Depth 10 -Compress))
}

$beforeAccepted = 0
$beforeRejected = 0

$cfgObj = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$acceptedRoot = Join-Path $RepoRoot (([string]$cfgObj.accepted_root).Replace('/','\'))
$rejectedRoot = Join-Path $RepoRoot (([string]$cfgObj.rejected_root).Replace('/','\'))

if(Test-Path -LiteralPath $acceptedRoot){ $beforeAccepted = @(Get-ChildItem -LiteralPath $acceptedRoot -Directory -ErrorAction SilentlyContinue).Count }
if(Test-Path -LiteralPath $rejectedRoot){ $beforeRejected = @(Get-ChildItem -LiteralPath $rejectedRoot -Directory -ErrorAction SilentlyContinue).Count }

try {
  & $Listen -RepoRoot $RepoRoot -ConfigPath $ConfigPath
}
catch {
  Append-Receipt $RepoRoot @{
    node_id = $NodeId
    status = "listen_error"
    error = $_.ToString()
    config_path = $ConfigPath
  }
  throw
}

$afterAccepted = @(Get-ChildItem -LiteralPath $acceptedRoot -Directory -ErrorAction SilentlyContinue).Count
$afterRejected = @(Get-ChildItem -LiteralPath $rejectedRoot -Directory -ErrorAction SilentlyContinue).Count

Append-Receipt $RepoRoot @{
  node_id = $NodeId
  status = "ok"
  config_path = $ConfigPath
  accepted_delta = ($afterAccepted - $beforeAccepted)
  rejected_delta = ($afterRejected - $beforeRejected)
}

Write-Host ("VTP_NODE_LOOP_OK: " + $NodeId)

if(-not $Once){
  Write-Host "VTP_NODE_LOOP_ONCE_ONLY_IN_V1"
}
